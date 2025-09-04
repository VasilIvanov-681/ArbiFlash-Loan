// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// EIP-3156 Interfaces
import {IERC3156FlashLenderUpgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC3156FlashLenderUpgradeable.sol";
import {IERC3156FlashBorrowerUpgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC3156FlashBorrowerUpgradeable.sol";

// OpenZeppelin contracts
import {IERC20Upgradeable as IERC20} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable as SafeERC20} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MulticallUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";

/**
 * @title Arbi Flash Loan
 * @author Flash Loan Protocol Team
 * @notice A finalized, EIP-3156 compliant, audit-ready flash loan provider with comprehensive security features
 * @dev Implements upgradeable pattern with UUPS proxy for mainnet deployment
 */
contract MainnetCandidateLender is 
    Initializable, 
    OwnableUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable, 
    MulticallUpgradeable, 
    IERC3156FlashLenderUpgradeable 
{
    using SafeERC20 for IERC20;

    // === Constants ===
    
    /// @notice Minimum cooldown period between loans for a borrower
    uint256 public constant MIN_COOLDOWN_BLOCKS = 1;
    
    /// @notice Maximum fee that can be charged (10%)
    uint256 public constant MAX_FEE_BPS = 1000;
    
    /// @notice Time delay for emergency withdrawals
    uint256 public constant EMERGENCY_DELAY = 3 days;
    
    /// @notice Maximum number of supported assets
    uint256 public constant MAX_SUPPORTED_ASSETS = 50;
    
    /// @notice Gas limit for flash loan callback
    uint256 private constant CALLBACK_GAS_LIMIT = 500_000;

    // === State Variables ===
    
    /// @notice Configuration for each supported asset
    struct AssetConfig {
        bool supported;
        uint96 maxLoan;
        uint16 feeBps;
        uint128 maxDailyVolume;
    }
    
    /// @notice Asset configurations
    mapping(address => AssetConfig) public assetConfig;
    
    /// @notice Total principal deposited per asset
    mapping(address => uint256) public totalPrincipal;
    
    /// @notice Accumulated fees per asset
    mapping(address => uint256) public accumulatedFees;
    
    /// @notice Last block when borrower took a loan
    mapping(address => uint256) public borrowerLastLoanBlock;
    
    /// @notice Cooldown period in blocks
    uint256 public borrowerCooldownBlocks;
    
    /// @notice Daily volume used per asset
    mapping(address => uint256) public dailyVolumeUsed;
    
    /// @notice Last day when volume was reset
    mapping(address => uint256) public lastResetDay;
    
    /// @notice Emergency withdrawal initiation timestamp
    mapping(address => uint256) public emergencyWithdrawalTimestamp;
    
    /// @notice Number of supported assets
    uint256 public supportedAssetCount;
    
    /// @notice Number of successful loans per asset
    mapping(address => uint256) public successfulLoansCount;

    // Risk Management
    
    /// @notice Maximum utilization allowed in basis points
    uint16 public maxUtilizationBps;
    
    /// @notice Threshold for triggering circuit breaker
    uint256 public anomalousActivityThreshold;
    
    /// @notice Current anomalous activity count
    uint256 public anomalousActivityCount;
    
    /// @notice Last time anomalous activity counter was reset
    uint256 public lastAnomalousActivityReset;

    // === Custom Errors ===
    
    error FlashLender__AssetNotSupported(address token);
    error FlashLender__ExceedsMaxLoanAmount(uint256 requested, uint256 max);
    error FlashLender__NotEnoughLiquidity(uint256 requested, uint256 available);
    error FlashLender__LoanNotRepaid();
    error FlashLender__CallbackFailed();
    error FlashLender__BorrowerInCooldown(uint256 lastBlock, uint256 cooldown);
    error FlashLender__WithdrawalExceedsPrincipal(uint256 requested, uint256 availablePrincipal);
    error FlashLender__InsufficientAvailableBalance();
    error FlashLender__CannotRecoverSupportedAsset();
    error FlashLender__InvalidCooldown(uint256 requested, uint256 min);
    error FlashLender__InvalidFee(uint256 requested, uint256 max);
    error FlashLender__DailyVolumeLimitExceeded(uint256 used, uint256 requested, uint256 limit);
    error FlashLender__InvalidAddress();
    error FlashLender__MaxAssetsReached();
    error FlashLender__NoSelfCall();
    error FlashLender__EmergencyDelayNotMet();
    error FlashLender__ExceedsMaxUtilization(uint256 utilization, uint256 max);
    error FlashLender__UnsupportedToken();
    error FlashLender__InvalidMaxUtilization();

    // === Events ===
    
    event FlashLoan(
        address indexed receiver, 
        address indexed initiator, 
        address indexed token, 
        uint256 amount, 
        uint256 fee
    );
    event AssetConfigUpdated(
        address indexed token, 
        bool supported, 
        uint96 maxLoan, 
        uint16 feeBps, 
        uint128 maxDailyVolume
    );
    event CooldownUpdated(uint256 newCooldown);
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event FeesSwept(address indexed token, address indexed to, uint256 amount);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdrawalInitiated(address indexed token, uint256 timestamp);
    event EmergencyWithdrawalExecuted(address indexed token, uint256 amount);
    event CircuitBreakerTriggered(uint256 failureCount);
    event CircuitBreakerReset();
    event AnomalousActivityThresholdUpdated(uint256 newThreshold);
    event MaxUtilizationUpdated(uint16 newMaxUtilization);

    // === Modifiers ===
    
    modifier noSelfCall() {
        if (msg.sender == address(this)) revert FlashLender__NoSelfCall();
        _;
    }

    // === Constructor ===
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // === Initializer ===
    
    /**
     * @notice Initializes the contract
     * @param initialOwner Address of the initial owner
     * @param _borrowerCooldownBlocks Cooldown period in blocks
     * @param _anomalousActivityThreshold Threshold for circuit breaker
     * @param _maxUtilizationBps Maximum utilization in basis points
     */
    function initialize(
        address initialOwner,
        uint256 _borrowerCooldownBlocks,
        uint256 _anomalousActivityThreshold,
        uint16 _maxUtilizationBps
    ) public initializer {
        __Ownable_init(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Multicall_init();
        
        if (_borrowerCooldownBlocks < MIN_COOLDOWN_BLOCKS) {
            revert FlashLender__InvalidCooldown(_borrowerCooldownBlocks, MIN_COOLDOWN_BLOCKS);
        }
        borrowerCooldownBlocks = _borrowerCooldownBlocks;
        
        anomalousActivityThreshold = _anomalousActivityThreshold;
        lastAnomalousActivityReset = block.timestamp;
        
        if (_maxUtilizationBps > 10000) {
            revert FlashLender__InvalidMaxUtilization();
        }
        maxUtilizationBps = _maxUtilizationBps;
    }

    // === External Functions ===
    
    /**
     * @notice Returns the maximum loan amount for a token
     * @param token The loan currency
     * @return The maximum loan amount
     */
    function maxFlashLoan(address token) external view override returns (uint256) {
        if (!assetConfig[token].supported) return 0;
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 available = balance > accumulatedFees[token] ? balance - accumulatedFees[token] : 0;
        uint256 maxConfigured = assetConfig[token].maxLoan;
        
        return available < maxConfigured ? available : maxConfigured;
    }

    /**
     * @notice Returns the fee for a flash loan
     * @param token The loan currency
     * @param amount The loan amount
     * @return The fee amount
     */
    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        if (!assetConfig[token].supported) revert FlashLender__UnsupportedToken();
        return (amount * assetConfig[token].feeBps) / 10000;
    }

    /**
     * @notice Executes a flash loan
     * @param receiver The receiver of the flash loan
     * @param token The loan currency
     * @param amount The loan amount
     * @param data Arbitrary data to pass to the receiver
     * @return Success status
     */
    function flashLoan(
        IERC3156FlashBorrowerUpgradeable receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override whenNotPaused nonReentrant returns (bool) {
        // Check cooldown
        if (block.number < borrowerLastLoanBlock[address(receiver)] + borrowerCooldownBlocks) {
            revert FlashLender__BorrowerInCooldown(
                borrowerLastLoanBlock[address(receiver)], 
                borrowerCooldownBlocks
            );
        }
        
        // Check liquidity
        uint256 availableBalance = IERC20(token).balanceOf(address(this));
        if (amount > availableBalance) {
            revert FlashLender__NotEnoughLiquidity(amount, availableBalance);
        }
        
        // Check asset configuration
        AssetConfig memory config = assetConfig[token];
        if (!config.supported) revert FlashLender__AssetNotSupported(token);
        if (amount > config.maxLoan) revert FlashLender__ExceedsMaxLoanAmount(amount, config.maxLoan);
        
        // Risk checks
        _checkUtilization(availableBalance, amount);
        _checkAndApplyDailyLimit(token, amount, config.maxDailyVolume);

        // Calculate fee
        uint256 fee = (amount * config.feeBps) / 10000;

        // Transfer loan amount
        IERC20(token).safeTransfer(address(receiver), amount);
        
        // Execute callback
        try IERC3156FlashBorrowerUpgradeable(receiver).onFlashLoan{gas: CALLBACK_GAS_LIMIT}(
            msg.sender, 
            token, 
            amount, 
            fee, 
            data
        ) returns (bytes32 result) {
            if (result != keccak256("ERC3156FlashBorrower.onFlashLoan")) {
                _triggerAnomalousActivity();
                revert FlashLender__CallbackFailed();
            }
        } catch {
            _triggerAnomalousActivity();
            revert FlashLender__CallbackFailed();
        }

        // Verify repayment
        uint256 expectedBalance = availableBalance + fee;
        if (IERC20(token).balanceOf(address(this)) < expectedBalance) {
            _triggerAnomalousActivity();
            revert FlashLender__LoanNotRepaid();
        }

        // Update state
        accumulatedFees[token] += fee;
        borrowerLastLoanBlock[address(receiver)] = block.number;
        successfulLoansCount[token]++;
        
        emit FlashLoan(address(receiver), msg.sender, token, amount, fee);
        return true;
    }

    // === Admin Functions ===
    
    /**
     * @notice Updates configuration for an asset
     * @param token The asset address
     * @param supported Whether the asset is supported
     * @param maxLoan Maximum loan amount
     * @param feeBps Fee in basis points
     * @param maxDailyVolume Maximum daily volume
     */
    function updateAssetConfig(
        address token,
        bool supported,
        uint96 maxLoan,
        uint16 feeBps,
        uint128 maxDailyVolume
    ) external onlyOwner {
        if (token == address(0)) revert FlashLender__InvalidAddress();
        if (feeBps > MAX_FEE_BPS) revert FlashLender__InvalidFee(feeBps, MAX_FEE_BPS);
        
        bool wasSupportedBefore = assetConfig[token].supported;
        
        if (supported && !wasSupportedBefore) {
            if (supportedAssetCount >= MAX_SUPPORTED_ASSETS) {
                revert FlashLender__MaxAssetsReached();
            }
            supportedAssetCount++;
        } else if (!supported && wasSupportedBefore) {
            supportedAssetCount--;
        }
        
        assetConfig[token] = AssetConfig({
            supported: supported,
            maxLoan: maxLoan,
            feeBps: feeBps,
            maxDailyVolume: maxDailyVolume
        });
        
        emit AssetConfigUpdated(token, supported, maxLoan, feeBps, maxDailyVolume);
    }

    /**
     * @notice Sets the borrower cooldown period
     * @param _borrowerCooldownBlocks New cooldown period in blocks
     */
    function setCooldownBlocks(uint256 _borrowerCooldownBlocks) external onlyOwner {
        if (_borrowerCooldownBlocks < MIN_COOLDOWN_BLOCKS) {
            revert FlashLender__InvalidCooldown(_borrowerCooldownBlocks, MIN_COOLDOWN_BLOCKS);
        }
        borrowerCooldownBlocks = _borrowerCooldownBlocks;
        emit CooldownUpdated(_borrowerCooldownBlocks);
    }

    /**
     * @notice Deposits funds to the protocol
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function deposit(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert FlashLender__InvalidAddress();
        if (!assetConfig[token].supported) revert FlashLender__AssetNotSupported(token);
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        totalPrincipal[token] += amount;
        
        emit Deposited(token, msg.sender, amount);
    }

    /**
     * @notice Withdraws principal from the protocol
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     */
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {

        if (token == address(0)) revert FlashLender__InvalidAddress();
