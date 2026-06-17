// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

struct PMFIPositionConfigV22 {
    address factory;
    address marketplace;
    address borrower;
    IERC20Metadata collateral;
    IERC20Metadata usdc;
    uint256 collateralAmount;
    uint256 targetRaiseUsdc;
    uint256 totalRepaymentUsdc;
    uint256 fundingDeadline;
    uint256 repaymentDeadline;
    string namePrefix;
    string symbolPrefix;
}

interface IPMFIPositionFactoryV22 {
    function USDC() external view returns (IERC20Metadata);
    function feeRecipient() external view returns (address);
    function isVault(address vault) external view returns (bool);
    function purchasesPaused() external view returns (bool);
}

interface IPMFIPositionVaultV22 {
    function borrower() external view returns (address);
    function P() external view returns (address);
    function initialCollateralAmount() external view returns (uint256);
    function targetRaiseUsdc() external view returns (uint256);
    function fundingDeadline() external view returns (uint256);
    function fundingClosed() external view returns (bool);
    function settled() external view returns (bool);
    function closeFunding(uint256 unsoldP) external;
}

interface IPMFIPrimaryMarketplaceV22 {
    function factory() external view returns (address);
    function registerPrimarySale(address vault) external returns (uint256 saleId);
}

/// @notice ERC-20 claim token controlled only by its position vault.
/// @dev N transfers can be disabled during funding so the borrower can always cancel/refund unsold P.
contract PMFILegTokenV22 is ERC20 {
    address public immutable vault;
    uint8 private immutable _tokenDecimals;
    bool public immutable transfersEnabled;

    error OnlyVault();
    error ZeroAddress();
    error TransfersDisabled();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address vault_, bool transfersEnabled_)
        ERC20(name_, symbol_)
    {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        _tokenDecimals = decimals_;
        transfersEnabled = transfersEnabled_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!transfersEnabled && from != address(0) && to != address(0)) {
            revert TransfersDisabled();
        }
        super._update(from, to, value);
    }
}

/// @notice One vault is one borrower's single collateralized PMFI position.
/// @dev No oracle and no liquidation. P is the payout claim; N is the reclaim right.
contract PMFIPositionVaultV22 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable marketplace;
    address public immutable borrower;

    IERC20Metadata public immutable collateral;
    IERC20Metadata public immutable usdc;
    PMFILegTokenV22 public immutable P;
    PMFILegTokenV22 public immutable N;

    uint8 public immutable collateralDecimals;
    uint8 public immutable usdcDecimals;

    uint256 public immutable initialCollateralAmount;
    uint256 public immutable targetRaiseUsdc;
    uint256 public immutable totalRepaymentUsdc;
    uint256 public immutable fundingDeadline;
    uint256 public immutable repaymentDeadline;

    bool public initialized;
    bool public fundingClosed;
    bool public settled;
    bool public closedWithoutOutstandingP;

    // Accounting for P+N pair exits and borrower full repayment.
    uint256 public pairedN;
    uint256 public exercisedN;
    uint256 public usdcPaid;

    // Remaining protocol-accounted collateral backing active position claims.
    // Direct token donations are intentionally excluded.
    uint256 public accountedCollateral;

    // Collateral reserved for the borrower after unsold P and matching N are burned.
    uint256 public collateralRefundClaim;

    uint256 public collateralPoolAtSettle;
    uint256 public usdcPoolAtSettle;
    uint256 public pSupplyAtSettle;

    // Remaining tracked USDC available to P holders after settlement.
    // Direct token donations are intentionally excluded.
    uint256 public usdcPoolRemaining;

    event PositionInitialized(
        address indexed borrower, uint256 collateralAmount, uint256 pMintedToMarketplace, uint256 nMintedToBorrower
    );
    event FundingClosed(uint256 unsoldP, uint256 collateralRefundClaimRecorded, uint256 timestamp);
    event CollateralRefundClaimed(address indexed borrower, address indexed recipient, uint256 amount);
    event RedeemPair(address indexed user, uint256 amount, uint256 collateralOut);
    event FullRepayment(address indexed borrower, uint256 nBurned, uint256 usdcPaid, uint256 collateralOut);
    event Settled(bool early, uint256 collateralPool, uint256 usdcPool, uint256 pSupply);
    event RedeemP(address indexed user, uint256 pAmount, uint256 collateralOut, uint256 usdcOut);

    error OnlyFactory();
    error OnlyMarketplace();
    error OnlyBorrower();
    error ZeroAddress();
    error ZeroAmount();
    error SameTokens();
    error BadDeadlines();
    error BadDecimals();
    error AlreadyInitialized();
    error NotInitialized();
    error AlreadyFundingClosed();
    error AlreadySettled();
    error FundingStillOpen();
    error RepaymentClosed();
    error TooEarly();
    error NotSettled();
    error NoPSupply();
    error InsufficientCollateral();
    error InsufficientUnsoldP();
    error InsufficientBorrowerN();
    error NoCollateralRefund();
    error FeeOnTransferUnsupported();
    error AccountingInvariantBroken();

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier onlyMarketplace() {
        if (msg.sender != marketplace) revert OnlyMarketplace();
        _;
    }

    constructor(PMFIPositionConfigV22 memory config) {
        if (
            config.factory == address(0) || config.marketplace == address(0) || config.borrower == address(0)
                || address(config.collateral) == address(0) || address(config.usdc) == address(0)
        ) revert ZeroAddress();
        if (address(config.collateral) == address(config.usdc)) revert SameTokens();
        if (
            config.collateralAmount == 0 || config.targetRaiseUsdc == 0
                || config.totalRepaymentUsdc <= config.targetRaiseUsdc
        ) revert ZeroAmount();
        if (config.fundingDeadline <= block.timestamp || config.repaymentDeadline <= config.fundingDeadline) {
            revert BadDeadlines();
        }

        uint8 cDec = config.collateral.decimals();
        uint8 uDec = config.usdc.decimals();
        if (cDec > 30 || uDec != 6) revert BadDecimals();

        factory = config.factory;
        marketplace = config.marketplace;
        borrower = config.borrower;
        collateral = config.collateral;
        usdc = config.usdc;
        collateralDecimals = cDec;
        usdcDecimals = uDec;
        initialCollateralAmount = config.collateralAmount;
        targetRaiseUsdc = config.targetRaiseUsdc;
        totalRepaymentUsdc = config.totalRepaymentUsdc;
        fundingDeadline = config.fundingDeadline;
        repaymentDeadline = config.repaymentDeadline;

        P = new PMFILegTokenV22(
            string.concat(config.namePrefix, " Payout P"),
            string.concat(config.symbolPrefix, "-P"),
            cDec,
            address(this),
            true
        );

        N = new PMFILegTokenV22(
            string.concat(config.namePrefix, " Reclaim N"),
            string.concat(config.symbolPrefix, "-N"),
            cDec,
            address(this),
            false
        );
    }

    /// @notice Initializes once after the factory has transferred the exact collateral amount.
    function initializePosition() external onlyFactory {
        if (initialized) revert AlreadyInitialized();
        if (collateral.balanceOf(address(this)) < initialCollateralAmount) {
            revert InsufficientCollateral();
        }

        initialized = true;
        accountedCollateral = initialCollateralAmount;
        P.mint(marketplace, initialCollateralAmount);
        N.mint(borrower, initialCollateralAmount);

        emit PositionInitialized(borrower, initialCollateralAmount, initialCollateralAmount, initialCollateralAmount);
    }

    /// @notice Marketplace closes funding and records unfunded collateral as a borrower claim.
    /// @dev No outbound collateral transfer occurs, so token failures cannot block lifecycle progress.
    function closeFunding(uint256 unsoldP) external onlyMarketplace nonReentrant {
        if (!initialized) revert NotInitialized();
        if (settled) revert AlreadySettled();
        if (fundingClosed) revert AlreadyFundingClosed();
        if (unsoldP > P.balanceOf(marketplace)) revert InsufficientUnsoldP();
        if (unsoldP > N.balanceOf(borrower)) revert InsufficientBorrowerN();

        fundingClosed = true;
        uint256 refundClaimRecorded;

        if (unsoldP > 0) {
            pairedN += unsoldP;
            P.burn(marketplace, unsoldP);
            N.burn(borrower, unsoldP);

            accountedCollateral -= unsoldP;
            collateralRefundClaim = unsoldP;
            refundClaimRecorded = unsoldP;
        }

        if (P.totalSupply() == 0) {
            closedWithoutOutstandingP = true;
        }

        _assertAccountingInvariant();
        emit FundingClosed(unsoldP, refundClaimRecorded, block.timestamp);
    }

    /// @notice Transfers collateral reserved for the borrower when funding closed with unsold P.
    /// @dev A failed transfer reverts the transaction and restores the claim for a later retry.
    function claimCollateralRefund(address recipient) external nonReentrant {
        if (msg.sender != borrower) revert OnlyBorrower();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 amount = collateralRefundClaim;
        if (amount == 0) revert NoCollateralRefund();

        collateralRefundClaim = 0;

        uint256 recipientBalanceBefore = collateral.balanceOf(recipient);
        IERC20(address(collateral)).safeTransfer(recipient, amount);
        uint256 recipientBalanceAfter = collateral.balanceOf(recipient);

        if (recipientBalanceAfter < recipientBalanceBefore || recipientBalanceAfter - recipientBalanceBefore != amount)
        {
            revert FeeOnTransferUnsupported();
        }

        emit CollateralRefundClaimed(msg.sender, recipient, amount);
    }

    /// @notice Burns matching P and N and returns matching collateral after funding closes.
    function redeemPair(uint256 amount) external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (!fundingClosed) revert FundingStillOpen();
        if (settled) revert AlreadySettled();
        if (amount == 0) revert ZeroAmount();

        pairedN += amount;
        accountedCollateral -= amount;
        P.burn(msg.sender, amount);
        N.burn(msg.sender, amount);
        IERC20(address(collateral)).safeTransfer(msg.sender, amount);

        if (P.totalSupply() == 0) {
            closedWithoutOutstandingP = true;
        }

        _assertAccountingInvariant();
        emit RedeemPair(msg.sender, amount, amount);
    }

    /// @notice Total repayment still required for all N that was not removed through P+N pairing.
    function repaymentRequiredUsdc() public view returns (uint256) {
        uint256 pairedCredit = Math.mulDiv(totalRepaymentUsdc, pairedN, initialCollateralAmount);
        return totalRepaymentUsdc - pairedCredit;
    }

    function repaymentRemainingUsdc() external view returns (uint256) {
        uint256 required = repaymentRequiredUsdc();
        return required > usdcPaid ? required - usdcPaid : 0;
    }

    /// @notice Repays the entire obligation for the P that was actually funded.
    /// @dev Only the borrower may repay. All remaining N is burned and all
    ///      protocol-accounted collateral is returned atomically.
    function repayInFull() external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (!fundingClosed) revert FundingStillOpen();
        if (settled) revert AlreadySettled();
        if (msg.sender != borrower) revert OnlyBorrower();
        if (block.timestamp > repaymentDeadline) {
            revert RepaymentClosed();
        }

        uint256 nAmount = N.totalSupply();
        if (nAmount == 0 || P.totalSupply() == 0) {
            revert NoPSupply();
        }

        if (N.balanceOf(borrower) != nAmount) {
            revert InsufficientBorrowerN();
        }

        if (accountedCollateral != nAmount || exercisedN != 0 || usdcPaid != 0) {
            revert AccountingInvariantBroken();
        }

        uint256 required = repaymentRequiredUsdc();

        // Effects occur before token interactions. Any failed transfer reverts
        // the complete transaction and restores all state and token balances.
        exercisedN = nAmount;
        usdcPaid = required;
        accountedCollateral = 0;
        N.burn(borrower, nAmount);

        uint256 vaultUsdcBefore = usdc.balanceOf(address(this));

        IERC20(address(usdc)).safeTransferFrom(borrower, address(this), required);

        uint256 vaultUsdcAfter = usdc.balanceOf(address(this));

        if (vaultUsdcAfter < vaultUsdcBefore || vaultUsdcAfter - vaultUsdcBefore != required) {
            revert FeeOnTransferUnsupported();
        }

        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);

        IERC20(address(collateral)).safeTransfer(borrower, nAmount);

        uint256 borrowerCollateralAfter = collateral.balanceOf(borrower);

        if (
            borrowerCollateralAfter < borrowerCollateralBefore
                || borrowerCollateralAfter - borrowerCollateralBefore != nAmount
        ) {
            revert FeeOnTransferUnsupported();
        }

        _assertAccountingInvariant();

        emit FullRepayment(borrower, nAmount, required, nAmount);
    }

    /// @notice Early settlement is possible only after all remaining N has been exercised.
    function canSettleEarly() public view returns (bool) {
        return initialized && fundingClosed && !settled && P.totalSupply() > 0 && N.totalSupply() == 0
            && usdcPaid == repaymentRequiredUsdc();
    }

    /// @notice Settles early after full repayment, or after the final repayment deadline.
    function settle() external nonReentrant {
        _settle();
    }

    /// @notice Convenience function for a P holder to settle when eligible and redeem in one transaction.
    function settleAndRedeemP(uint256 amount) external nonReentrant {
        if (!settled) _settle();
        _redeemP(msg.sender, amount);
    }

    function _settle() internal {
        if (!initialized) revert NotInitialized();
        if (!fundingClosed) revert FundingStillOpen();
        if (settled) revert AlreadySettled();

        bool early = canSettleEarly();
        bool deadlinePassed = block.timestamp > repaymentDeadline;
        if (!early && !deadlinePassed) revert TooEarly();

        uint256 pSupply = P.totalSupply();
        if (pSupply == 0) revert NoPSupply();

        settled = true;

        // Binary settlement:
        // - full repayment gives P holders USDC only;
        // - default gives P holders accounted collateral only.
        collateralPoolAtSettle = early ? 0 : accountedCollateral;
        usdcPoolAtSettle = early ? usdcPaid : 0;
        usdcPoolRemaining = usdcPoolAtSettle;
        pSupplyAtSettle = pSupply;

        emit Settled(early, collateralPoolAtSettle, usdcPoolAtSettle, pSupplyAtSettle);
    }

    /// @notice Preview P redemption after settlement.
    /// @dev Claims use remaining tracked pools and the current P supply.
    ///      Direct token donations never create redemption entitlements.
    function previewRedeemP(uint256 amount) public view returns (uint256 collateralOut, uint256 usdcOut) {
        if (!settled) revert NotSettled();
        if (amount == 0) revert ZeroAmount();

        uint256 currentSupply = P.totalSupply();

        if (currentSupply == 0 || pSupplyAtSettle == 0) {
            revert NoPSupply();
        }

        collateralOut = Math.mulDiv(accountedCollateral, amount, currentSupply);

        usdcOut = Math.mulDiv(usdcPoolRemaining, amount, currentSupply);
    }

    function redeemP(uint256 amount) external nonReentrant {
        _redeemP(msg.sender, amount);
    }

    function _redeemP(address user, uint256 amount) internal {
        (uint256 collateralOut, uint256 usdcOut) = previewRedeemP(amount);
        P.burn(user, amount);

        if (collateralOut > 0) {
            accountedCollateral -= collateralOut;
            IERC20(address(collateral)).safeTransfer(user, collateralOut);
        }
        if (usdcOut > 0) {
            usdcPoolRemaining -= usdcOut;
            IERC20(address(usdc)).safeTransfer(user, usdcOut);
        }

        emit RedeemP(user, amount, collateralOut, usdcOut);
    }

    function legAddresses() external view returns (address pToken, address nToken) {
        return (address(P), address(N));
    }

    function _assertAccountingInvariant() internal view {
        if (pairedN + exercisedN + N.totalSupply() != initialCollateralAmount) {
            revert AccountingInvariantBroken();
        }
    }
}

/// @notice Factory, registry, collateral policy, and limited emergency controls for PMFI positions.
/// @dev Pause controls only block new positions and new purchases. User exits are never paused.
contract PMFIPositionFactoryV22 is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant CREATION_FEE = 0.0001 ether;
    uint256 public constant MIN_FUNDING_PERIOD = 1 hours;
    uint256 public constant MAX_FUNDING_PERIOD = 30 days;
    uint256 public constant MAX_REPAYMENT_PERIOD = 365 days;
    uint256 public constant MAX_PREFIX_BYTES = 32;

    IERC20Metadata public immutable USDC;
    address public immutable feeRecipient;
    address public immutable marketplace;

    bool public permissionlessCollateral;
    bool public creationPaused;
    bool public purchasesPaused;

    address[] public allVaults;
    mapping(address => bool) public isVault;
    mapping(address => address) public creatorOf;
    mapping(address => bool) public collateralAllowed;

    event PositionCreated(
        address indexed borrower,
        address indexed vault,
        address indexed collateral,
        address pToken,
        address nToken,
        uint256 collateralAmount,
        uint256 targetRaiseUsdc,
        uint256 totalRepaymentUsdc,
        uint256 fundingDeadline,
        uint256 repaymentDeadline,
        uint256 saleId
    );
    event CollateralAllowed(address indexed collateral, bool allowed);
    event PermissionlessCollateralSet(bool enabled);
    event CreationPausedSet(bool paused);
    event PurchasesPausedSet(bool paused);
    event CreationFeesWithdrawn(address indexed recipient, uint256 amount);

    error ZeroAddress();
    error SameTokens();
    error NoCode();
    error WrongCreationFee();
    error OnlyFeeRecipient();
    error CreationPaused();
    error CollateralNotAllowed();
    error BadAmounts();
    error BadDeadlines();
    error BadUsdcDecimals();
    error BadCollateralDecimals();
    error BadPrefix();
    error FeeOnTransferUnsupported();
    error NoFees();
    error EthTransferFailed();

    struct CreatePositionParams {
        IERC20Metadata collateral;
        uint256 collateralAmount;
        uint256 targetRaiseUsdc;
        uint256 totalRepaymentUsdc;
        uint256 fundingDeadline;
        uint256 repaymentDeadline;
        string namePrefix;
        string symbolPrefix;
    }

    constructor(IERC20Metadata usdc_, address feeRecipient_, address initialOwner_) Ownable(initialOwner_) {
        if (address(usdc_) == address(0) || feeRecipient_ == address(0) || initialOwner_ == address(0)) {
            revert ZeroAddress();
        }
        if (address(usdc_).code.length == 0) revert NoCode();
        if (usdc_.decimals() != 6) revert BadUsdcDecimals();

        USDC = usdc_;
        feeRecipient = feeRecipient_;

        PMFIPrimaryMarketplaceV22 deployedMarketplace =
            new PMFIPrimaryMarketplaceV22(address(this), usdc_, feeRecipient_);
        marketplace = address(deployedMarketplace);
    }

    function setCollateralAllowed(address collateral_, bool allowed) external onlyOwner {
        if (collateral_ == address(0)) revert ZeroAddress();
        collateralAllowed[collateral_] = allowed;
        emit CollateralAllowed(collateral_, allowed);
    }

    function setPermissionlessCollateral(bool enabled) external onlyOwner {
        permissionlessCollateral = enabled;
        emit PermissionlessCollateralSet(enabled);
    }

    function setCreationPaused(bool paused) external onlyOwner {
        creationPaused = paused;
        emit CreationPausedSet(paused);
    }

    function setPurchasesPaused(bool paused) external onlyOwner {
        purchasesPaused = paused;
        emit PurchasesPausedSet(paused);
    }

    /// @notice Creates, collateralizes, mints, verifies, and lists one borrower position atomically.
    /// @dev User first approves the exact collateral amount to this factory.
    function createPosition(CreatePositionParams calldata params)
        external
        payable
        nonReentrant
        returns (address vault, uint256 saleId)
    {
        if (creationPaused) revert CreationPaused();
        if (msg.value != CREATION_FEE) revert WrongCreationFee();

        address collateralAddress = address(params.collateral);
        if (collateralAddress == address(0)) revert ZeroAddress();
        if (collateralAddress == address(USDC)) revert SameTokens();
        if (collateralAddress.code.length == 0) revert NoCode();
        if (!permissionlessCollateral && !collateralAllowed[collateralAddress]) {
            revert CollateralNotAllowed();
        }
        if (params.collateral.decimals() > 30) revert BadCollateralDecimals();
        if (
            params.collateralAmount == 0 || params.targetRaiseUsdc == 0
                || params.totalRepaymentUsdc <= params.targetRaiseUsdc
        ) revert BadAmounts();

        if (params.fundingDeadline <= block.timestamp) revert BadDeadlines();
        uint256 fundingPeriod = params.fundingDeadline - block.timestamp;
        if (
            fundingPeriod < MIN_FUNDING_PERIOD || fundingPeriod > MAX_FUNDING_PERIOD
                || params.repaymentDeadline <= params.fundingDeadline
                || params.repaymentDeadline - params.fundingDeadline > MAX_REPAYMENT_PERIOD
        ) revert BadDeadlines();

        uint256 nameLength = bytes(params.namePrefix).length;
        uint256 symbolLength = bytes(params.symbolPrefix).length;
        if (nameLength == 0 || symbolLength == 0 || nameLength > MAX_PREFIX_BYTES || symbolLength > MAX_PREFIX_BYTES) {
            revert BadPrefix();
        }

        PMFIPositionConfigV22 memory config = PMFIPositionConfigV22({
            factory: address(this),
            marketplace: marketplace,
            borrower: msg.sender,
            collateral: params.collateral,
            usdc: USDC,
            collateralAmount: params.collateralAmount,
            targetRaiseUsdc: params.targetRaiseUsdc,
            totalRepaymentUsdc: params.totalRepaymentUsdc,
            fundingDeadline: params.fundingDeadline,
            repaymentDeadline: params.repaymentDeadline,
            namePrefix: params.namePrefix,
            symbolPrefix: params.symbolPrefix
        });

        PMFIPositionVaultV22 v = new PMFIPositionVaultV22(config);
        vault = address(v);

        uint256 beforeBal = params.collateral.balanceOf(vault);
        IERC20(collateralAddress).safeTransferFrom(msg.sender, vault, params.collateralAmount);
        uint256 received = params.collateral.balanceOf(vault) - beforeBal;
        if (received != params.collateralAmount) revert FeeOnTransferUnsupported();

        v.initializePosition();

        isVault[vault] = true;
        creatorOf[vault] = msg.sender;
        allVaults.push(vault);

        saleId = IPMFIPrimaryMarketplaceV22(marketplace).registerPrimarySale(vault);

        _emitPositionCreated(v, params, saleId);
    }

    function _emitPositionCreated(PMFIPositionVaultV22 v, CreatePositionParams calldata params, uint256 saleId)
        internal
    {
        emit PositionCreated(
            msg.sender,
            address(v),
            address(params.collateral),
            address(v.P()),
            address(v.N()),
            params.collateralAmount,
            params.targetRaiseUsdc,
            params.totalRepaymentUsdc,
            params.fundingDeadline,
            params.repaymentDeadline,
            saleId
        );
    }

    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    function withdrawCreationFees() external nonReentrant {
        if (msg.sender != feeRecipient) revert OnlyFeeRecipient();
        uint256 amount = address(this).balance;
        if (amount == 0) revert NoFees();

        (bool ok,) = payable(feeRecipient).call{value: amount}("");
        if (!ok) revert EthTransferFailed();

        emit CreationFeesWithdrawn(feeRecipient, amount);
    }
}

/// @notice Verified primary marketplace for factory-created P claims settled only in official USDC.
contract PMFIPrimaryMarketplaceV22 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SALE_FEE_BPS = 10;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable factory;
    IERC20Metadata public immutable USDC;
    address public immutable feeRecipient;

    uint256 public accruedProtocolFees;

    struct Sale {
        address vault;
        address seller;
        IERC20Metadata pToken;
        uint256 amountInitial;
        uint256 amountRemaining;
        uint256 usdcTotal;
        uint256 usdcRemaining;
        uint256 usdcRaisedToSeller;
        uint256 feeAccrued;
        uint256 expiry;
        bool active;
    }

    Sale[] public sales;
    mapping(address => uint256) public saleIdPlusOneByVault;

    event SaleRegistered(
        uint256 indexed saleId,
        address indexed vault,
        address indexed seller,
        address pToken,
        address usdc,
        uint256 pAmount,
        uint256 totalUsdcPrice,
        uint256 expiry
    );
    event Bought(
        uint256 indexed saleId,
        address indexed buyer,
        uint256 pAmount,
        uint256 sellerPrice,
        uint256 feeAmount,
        uint256 totalPaid
    );
    event SaleClosed(uint256 indexed saleId, uint256 pBurnedAsUnfunded, bool fullyFilled, bool expired);
    event ProtocolFeesWithdrawn(address indexed recipient, uint256 amount);

    error OnlyFactory();
    error OnlyFeeRecipient();
    error UnverifiedVault();
    error DuplicateSale();
    error WrongEscrowBalance();
    error ZeroAmount();
    error ZeroPrice();
    error BadExpiry();
    error NotActive();
    error SaleExpired();
    error PurchasesPaused();
    error FundingClosed();
    error AlreadySettled();
    error TooMuch();
    error ZeroUsdcCost();
    error MaxPaymentExceeded();
    error NotSeller();
    error FeeOnTransferUnsupported();
    error NoFees();

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    constructor(address factory_, IERC20Metadata usdc_, address feeRecipient_) {
        if (factory_ == address(0) || address(usdc_) == address(0) || feeRecipient_ == address(0)) {
            revert UnverifiedVault();
        }
        factory = factory_;
        USDC = usdc_;
        feeRecipient = feeRecipient_;
    }

    /// @notice Registers the one verified primary P sale for a newly created vault.
    /// @dev Terms are derived from the factory-created vault, not supplied by an arbitrary caller.
    function registerPrimarySale(address vault) external onlyFactory returns (uint256 saleId) {
        IPMFIPositionFactoryV22 f = IPMFIPositionFactoryV22(factory);
        if (!f.isVault(vault)) revert UnverifiedVault();
        if (saleIdPlusOneByVault[vault] != 0) revert DuplicateSale();

        IPMFIPositionVaultV22 v = IPMFIPositionVaultV22(vault);
        address seller = v.borrower();
        uint256 pAmount = v.initialCollateralAmount();
        uint256 totalUsdcPrice = v.targetRaiseUsdc();
        uint256 expiry = v.fundingDeadline();
        IERC20Metadata pToken = IERC20Metadata(v.P());

        if (seller == address(0)) revert UnverifiedVault();
        if (pAmount == 0) revert ZeroAmount();
        if (totalUsdcPrice == 0) revert ZeroPrice();
        if (expiry <= block.timestamp) revert BadExpiry();
        if (pToken.balanceOf(address(this)) != pAmount) revert WrongEscrowBalance();

        sales.push(
            Sale({
                vault: vault,
                seller: seller,
                pToken: pToken,
                amountInitial: pAmount,
                amountRemaining: pAmount,
                usdcTotal: totalUsdcPrice,
                usdcRemaining: totalUsdcPrice,
                usdcRaisedToSeller: 0,
                feeAccrued: 0,
                expiry: expiry,
                active: true
            })
        );

        saleId = sales.length - 1;
        saleIdPlusOneByVault[vault] = saleId + 1;

        emit SaleRegistered(saleId, vault, seller, address(pToken), address(USDC), pAmount, totalUsdcPrice, expiry);
    }

    /// @notice Quotes seller proceeds for a partial fill. Final fill includes all quote dust.
    function quoteUsdc(uint256 saleId, uint256 pAmount) public view returns (uint256) {
        Sale storage s = sales[saleId];
        if (pAmount == 0) revert ZeroAmount();
        if (pAmount > s.amountRemaining) revert TooMuch();
        if (pAmount == s.amountRemaining) return s.usdcRemaining;
        return Math.mulDiv(s.usdcTotal, pAmount, s.amountInitial);
    }

    /// @notice Cumulative fee calculation makes the final fee independent of fill splitting.
    function quoteFee(uint256 saleId, uint256 sellerPrice) public view returns (uint256) {
        Sale storage s = sales[saleId];
        uint256 cumulativeFee = Math.mulDiv(s.usdcRaisedToSeller + sellerPrice, SALE_FEE_BPS, BPS_DENOMINATOR);
        return cumulativeFee - s.feeAccrued;
    }

    function quoteTotalPayment(uint256 saleId, uint256 pAmount)
        external
        view
        returns (uint256 sellerPrice, uint256 feeAmount, uint256 totalPaid)
    {
        sellerPrice = quoteUsdc(saleId, pAmount);
        feeAmount = quoteFee(saleId, sellerPrice);
        totalPaid = sellerPrice + feeAmount;
    }

    /// @notice Buys a partial amount of verified P with official USDC.
    /// @param maxTotalPayment User-provided slippage ceiling; protects against stale UI quotes.
    function buy(uint256 saleId, uint256 pAmount, uint256 maxTotalPayment) external nonReentrant {
        if (IPMFIPositionFactoryV22(factory).purchasesPaused()) revert PurchasesPaused();

        Sale storage s = sales[saleId];
        if (!s.active) revert NotActive();
        if (block.timestamp >= s.expiry) revert SaleExpired();
        if (IPMFIPositionVaultV22(s.vault).fundingClosed()) revert FundingClosed();
        if (IPMFIPositionVaultV22(s.vault).settled()) revert AlreadySettled();

        uint256 sellerPrice = quoteUsdc(saleId, pAmount);
        if (sellerPrice == 0) revert ZeroUsdcCost();
        uint256 feeAmount = quoteFee(saleId, sellerPrice);
        uint256 totalPaid = sellerPrice + feeAmount;
        if (totalPaid > maxTotalPayment) revert MaxPaymentExceeded();

        s.amountRemaining -= pAmount;
        s.usdcRemaining -= sellerPrice;
        s.usdcRaisedToSeller += sellerPrice;
        s.feeAccrued += feeAmount;
        accruedProtocolFees += feeAmount;

        uint256 beforeBal = USDC.balanceOf(address(this));
        IERC20(address(USDC)).safeTransferFrom(msg.sender, address(this), totalPaid);
        uint256 received = USDC.balanceOf(address(this)) - beforeBal;
        if (received != totalPaid) revert FeeOnTransferUnsupported();

        IERC20(address(USDC)).safeTransfer(s.seller, sellerPrice);
        IERC20(address(s.pToken)).safeTransfer(msg.sender, pAmount);

        bool filled = s.amountRemaining == 0;
        if (filled) {
            s.active = false;
            IPMFIPositionVaultV22(s.vault).closeFunding(0);
            emit SaleClosed(saleId, 0, true, false);
        }

        emit Bought(saleId, msg.sender, pAmount, sellerPrice, feeAmount, totalPaid);
    }

    /// @notice Borrower cancels the unsold remainder; matching N is burned and collateral refunded atomically.
    function cancel(uint256 saleId) external nonReentrant {
        Sale storage s = sales[saleId];
        if (!s.active) revert NotActive();
        if (msg.sender != s.seller) revert NotSeller();

        uint256 remaining = _closeSale(saleId);
        emit SaleClosed(saleId, remaining, false, false);
    }

    /// @notice Anyone may close an expired sale and complete the unfunded refund path.
    function closeExpired(uint256 saleId) external nonReentrant {
        Sale storage s = sales[saleId];
        if (!s.active) revert NotActive();
        if (block.timestamp < s.expiry) revert BadExpiry();

        uint256 remaining = _closeSale(saleId);
        emit SaleClosed(saleId, remaining, false, true);
    }

    function _closeSale(uint256 saleId) internal returns (uint256 remaining) {
        Sale storage s = sales[saleId];
        remaining = s.amountRemaining;

        s.amountRemaining = 0;
        s.usdcRemaining = 0;
        s.active = false;

        IPMFIPositionVaultV22(s.vault).closeFunding(remaining);
    }

    function withdrawProtocolFees() external nonReentrant {
        if (msg.sender != feeRecipient) revert OnlyFeeRecipient();
        uint256 amount = accruedProtocolFees;
        if (amount == 0) revert NoFees();

        accruedProtocolFees = 0;
        IERC20(address(USDC)).safeTransfer(feeRecipient, amount);

        emit ProtocolFeesWithdrawn(feeRecipient, amount);
    }

    function salesLength() external view returns (uint256) {
        return sales.length;
    }
}
