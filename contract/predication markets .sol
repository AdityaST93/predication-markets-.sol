// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title PredictionMarkets
 * @dev A decentralized prediction market platform for betting on future events
 * @author Prediction Markets Team
 */
contract PredictionMarkets is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Enums
    enum MarketStatus { Active, Resolved, Cancelled }
    enum Outcome { Pending, Yes, No }

    // Events
    event MarketCreated(
        uint256 indexed marketId,
        string question,
        uint256 endTime,
        address creator
    );

    event BetPlaced(
        uint256 indexed marketId,
        address indexed bettor,
        Outcome prediction,
        uint256 amount,
        uint256 timestamp
    );

    event MarketResolved(
        uint256 indexed marketId,
        Outcome outcome,
        uint256 totalPayout,
        uint256 timestamp
    );

    event WinningsWithdrawn(
        address indexed user,
        uint256 indexed marketId,
        uint256 amount
    );

    event MarketCancelled(uint256 indexed marketId, string reason);

    // Structs
    struct Market {
        uint256 id;
        string question;
        string description;
        address creator;
        uint256 creationTime;
        uint256 endTime;
        uint256 resolutionTime;
        MarketStatus status;
        Outcome outcome;
        uint256 totalYesBets;
        uint256 totalNoBets;
        uint256 totalBets;
        mapping(address => UserBet) userBets;
        address[] bettors;
        uint256 creatorFee; // Fee percentage (basis points, e.g., 250 = 2.5%)
    }

    struct UserBet {
        uint256 yesBetAmount;
        uint256 noBetAmount;
        bool hasWithdrawn;
    }

    struct MarketInfo {
        uint256 id;
        string question;
        string description;
        address creator;
        uint256 creationTime;
        uint256 endTime;
        uint256 resolutionTime;
        MarketStatus status;
        Outcome outcome;
        uint256 totalYesBets;
        uint256 totalNoBets;
        uint256 totalBets;
        uint256 creatorFee;
    }

    // State variables
    mapping(uint256 => Market) public markets;
    mapping(address => bool) public oracles;
    mapping(address => uint256[]) public userMarkets;
    
    uint256 public nextMarketId;
    uint256 public platformFee; // Platform fee in basis points (e.g., 100 = 1%)
    uint256 public minimumBet;
    uint256 public minimumMarketDuration;
    
    IERC20 public bettingToken;
    address public feeRecipient;

    modifier onlyOracle() {
        require(oracles[msg.sender] || msg.sender == owner(), "Not authorized oracle");
        _;
    }

    modifier validMarket(uint256 marketId) {
        require(marketId < nextMarketId, "Market does not exist");
        _;
    }

    modifier marketActive(uint256 marketId) {
        require(markets[marketId].status == MarketStatus.Active, "Market not active");
        require(block.timestamp < markets[marketId].endTime, "Market ended");
        _;
    }

    constructor(
        address _bettingToken,
        uint256 _platformFee,
        uint256 _minimumBet,
        uint256 _minimumMarketDuration,
        address _feeRecipient,
        address _initialOwner
    ) Ownable(_initialOwner) {
        bettingToken = IERC20(_bettingToken);
        platformFee = _platformFee;
        minimumBet = _minimumBet;
        minimumMarketDuration = _minimumMarketDuration;
        feeRecipient = _feeRecipient;
        nextMarketId = 0;
    }

    /**
     * @dev Create a new prediction market
     * @param question The question being predicted
     * @param description Detailed description of the market
     * @param duration Duration in seconds from now until market ends
     * @param creatorFee Fee percentage for market creator (basis points)
     */
    function createMarket(
        string memory question,
        string memory description,
        uint256 duration,
        uint256 creatorFee
    ) external returns (uint256) {
        require(bytes(question).length > 0, "Question cannot be empty");
        require(duration >= minimumMarketDuration, "Duration too short");
        require(creatorFee <= 1000, "Creator fee too high"); // Max 10%

        uint256 marketId = nextMarketId++;
        Market storage market = markets[marketId];
        
        market.id = marketId;
        market.question = question;
        market.description = description;
        market.creator = msg.sender;
        market.creationTime = block.timestamp;
        market.endTime = block.timestamp.add(duration);
        market.status = MarketStatus.Active;
        market.outcome = Outcome.Pending;
        market.creatorFee = creatorFee;

        userMarkets[msg.sender].push(marketId);

        emit MarketCreated(marketId, question, market.endTime, msg.sender);
        return marketId;
    }

    /**
     * @dev Place a bet on a market outcome
     * @param marketId ID of the market to bet on
     * @param prediction Predicted outcome (Yes or No)
     * @param amount Amount of tokens to bet
     */
    function placeBet(
        uint256 marketId,
        Outcome prediction,
        uint256 amount
    ) external nonReentrant validMarket(marketId) marketActive(marketId) {
        require(prediction == Outcome.Yes || prediction == Outcome.No, "Invalid prediction");
        require(amount >= minimumBet, "Bet amount too low");

        Market storage market = markets[marketId];
        UserBet storage userBet = market.userBets[msg.sender];

        // Transfer tokens from user to contract
        bettingToken.safeTransferFrom(msg.sender, address(this), amount);

        // Add user to bettors list if first bet
        if (userBet.yesBetAmount == 0 && userBet.noBetAmount == 0) {
            market.bettors.push(msg.sender);
            userMarkets[msg.sender].push(marketId);
        }

        // Update bet amounts
        if (prediction == Outcome.Yes) {
            userBet.yesBetAmount = userBet.yesBetAmount.add(amount);
            market.totalYesBets = market.totalYesBets.add(amount);
        } else {
            userBet.noBetAmount = userBet.noBetAmount.add(amount);
            market.totalNoBets = market.totalNoBets.add(amount);
        }

        market.totalBets = market.totalBets.add(amount);

        emit BetPlaced(marketId, msg.sender, prediction, amount, block.timestamp);
    }

    /**
     * @dev Resolve a market with the final outcome
     * @param marketId ID of the market to resolve
     * @param outcome Final outcome of the market
     */
    function resolveMarket(
        uint256 marketId,
        Outcome outcome
    ) external onlyOracle validMarket(marketId) {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Active, "Market not active");
        require(block.timestamp >= market.endTime, "Market still active");
        require(outcome == Outcome.Yes || outcome == Outcome.No, "Invalid outcome");

        market.status = MarketStatus.Resolved;
        market.outcome = outcome;
        market.resolutionTime = block.timestamp;

        // Calculate total payout to winners
        uint256 winningPool = outcome == Outcome.Yes ? market.totalYesBets : market.totalNoBets;
        uint256 losingPool = outcome == Outcome.Yes ? market.totalNoBets : market.totalYesBets;
        
        uint256 totalPayout = winningPool.add(losingPool);

        emit MarketResolved(marketId, outcome, totalPayout, block.timestamp);
    }

    /**
     * @dev Withdraw winnings from a resolved market
     * @param marketId ID of the resolved market
     */
    function withdrawWinnings(uint256 marketId) external nonReentrant validMarket(marketId) {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Resolved, "Market not resolved");
        
        UserBet storage userBet = market.userBets[msg.sender];
        require(!userBet.hasWithdrawn, "Already withdrawn");

        uint256 winnings = calculateWinnings(marketId, msg.sender);
        require(winnings > 0, "No winnings to withdraw");

        userBet.hasWithdrawn = true;

        // Transfer winnings to user
        bettingToken.safeTransfer(msg.sender, winnings);

        emit WinningsWithdrawn(msg.sender, marketId, winnings);
    }

    /**
     * @dev Cancel a market (emergency function)
     * @param marketId ID of the market to cancel
     * @param reason Reason for cancellation
     */
    function cancelMarket(
        uint256 marketId,
        string memory reason
    ) external onlyOracle validMarket(marketId) {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Active, "Market not active");

        market.status = MarketStatus.Cancelled;

        // Refund all bettors
        for (uint256 i = 0; i < market.bettors.length; i++) {
            address bettor = market.bettors[i];
            UserBet storage userBet = market.userBets[bettor];
            
            if (!userBet.hasWithdrawn) {
                uint256 refundAmount = userBet.yesBetAmount.add(userBet.noBetAmount);
                if (refundAmount > 0) {
                    userBet.hasWithdrawn = true;
                    bettingToken.safeTransfer(bettor, refundAmount);
                }
            }
        }

        emit MarketCancelled(marketId, reason);
    }

    /**
     * @dev Calculate potential winnings for a user in a market
     * @param marketId ID of the market
     * @param user Address of the user
     */
    function calculateWinnings(uint256 marketId, address user) public view returns (uint256) {
        Market storage market = markets[marketId];
        UserBet storage userBet = market.userBets[user];

        if (market.status != MarketStatus.Resolved) {
            return 0;
        }

        uint256 userWinningBets = market.outcome == Outcome.Yes ? 
            userBet.yesBetAmount : userBet.noBetAmount;
        
        if (userWinningBets == 0) {
            return 0;
        }

        uint256 totalWinningBets = market.outcome == Outcome.Yes ? 
            market.totalYesBets : market.totalNoBets;
        uint256 totalLosingBets = market.outcome == Outcome.Yes ? 
            market.totalNoBets : market.totalYesBets;

        // Calculate winnings: original bet + proportional share of losing bets (minus fees)
        uint256 platformFeeAmount = totalLosingBets.mul(platformFee).div(10000);
        uint256 creatorFeeAmount = totalLosingBets.mul(market.creatorFee).div(10000);
        uint256 netLosingBets = totalLosingBets.sub(platformFeeAmount).sub(creatorFeeAmount);

        uint256 proportionalWinnings = netLosingBets.mul(userWinningBets).div(totalWinningBets);
        
        return userWinningBets.add(proportionalWinnings);
    }

    /**
     * @dev Get market information
     * @param marketId ID of the market
     */
    function getMarketInfo(uint256 marketId) external view validMarket(marketId) returns (MarketInfo memory) {
        Market storage market = markets[marketId];
        
        return MarketInfo({
            id: market.id,
            question: market.question,
            description: market.description,
            creator: market.creator,
            creationTime: market.creationTime,
            endTime: market.endTime,
            resolutionTime: market.resolutionTime,
            status: market.status,
            outcome: market.outcome,
            totalYesBets: market.totalYesBets,
            totalNoBets: market.totalNoBets,
            totalBets: market.totalBets,
            creatorFee: market.creatorFee
        });
    }

    /**
     * @dev Get user's bet information for a market
     * @param marketId ID of the market
     * @param user Address of the user
     */
    function getUserBet(uint256 marketId, address user) external view validMarket(marketId) returns (UserBet memory) {
        return markets[marketId].userBets[user];
    }

    /**
     * @dev Get markets created or participated by a user
     * @param user Address of the user
     */
    function getUserMarkets(address user) external view returns (uint256[] memory) {
        return userMarkets[user];
    }

    /**
     * @dev Add oracle address
     * @param oracle Address to add as oracle
     */
    function addOracle(address oracle) external onlyOwner {
        require(oracle != address(0), "Invalid oracle address");
        oracles[oracle] = true;
    }

    /**
     * @dev Remove oracle address
     * @param oracle Address to remove from oracles
     */
    function removeOracle(address oracle) external onlyOwner {
        oracles[oracle] = false;
    }

    /**
     * @dev Set platform fee
     * @param _platformFee New platform fee in basis points
     */
    function setPlatformFee(uint256 _platformFee) external onlyOwner {
        require(_platformFee <= 1000, "Fee too high"); // Max 10%
        platformFee = _platformFee;
    }

    /**
     * @dev Set minimum bet amount
     * @param _minimumBet New minimum bet amount
     */
    function setMinimumBet(uint256 _minimumBet) external onlyOwner {
        minimumBet = _minimumBet;
    }

    /**
     * @dev Set fee recipient
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid address");
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Get total number of markets
     */
    function getTotalMarkets() external view returns (uint256) {
        return nextMarketId;
    }

    /**
     * @dev Get market odds (returns basis points)
     * @param marketId ID of the market
     */
    function getMarketOdds(uint256 marketId) external view validMarket(marketId) returns (uint256 yesOdds, uint256 noOdds) {
        Market storage market = markets[marketId];
        
        if (market.totalBets == 0) {
            return (5000, 5000); // 50-50 if no bets
        }

        yesOdds = market.totalYesBets.mul(10000).div(market.totalBets);
        noOdds = market.totalNoBets.mul(10000).div(market.totalBets);
    }
}
