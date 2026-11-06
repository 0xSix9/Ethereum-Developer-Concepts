// SPDX-License-Identifier: EVVM-NONCOMMERCIAL-1.0
pragma solidity ^0.8.24;

interface IEVVMCore {
    function addAmountToUser(address user, address token, uint256 amount) external;
    function removeAmountFromUser(address user, address token, uint256 amount) external;
    function getBalance(address user, address token) external view returns (uint256);
    function getPrincipalTokenAddress() external view returns (address);
    function isAddressStaker(address user) external view returns (bool);
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC3009 {
    function receiveWithAuthorization(
        address from, address to, uint256 value, uint256 validAfter,
        uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s
    ) external;
}

/// @notice Reference Treasury for an optional ERC-3009 relayed-deposit path.
/// @dev Must be configured as Core.treasuryAddress on a new EVVM instance.
///      This is a PoC, not audited or production-ready.
contract EVVMERC3009Treasury {
    uint256 public constant BPS = 10_000;
    bytes32 public constant NONCE_TYPEHASH = keccak256(
        "GaslessDeposit(uint256 chainId,address treasury,address from,address token,uint256 depositAmount,uint256 feeAmount,address executor,bytes32 salt)"
    );

    IEVVMCore public immutable core;
    address public immutable protocolFeeRecipient;
    uint16 public immutable protocolFeeBps;
    mapping(address => bool) public supportedERC3009Token;
    bool private entered;

    error InvalidAddress();
    error InvalidConfiguration();
    error InvalidAmount();
    error InvalidNativeValue();
    error UnsupportedToken();
    error PrincipalTokenNotSupported();
    error CallerNotStaker();
    error UnauthorizedExecutor();
    error ReentrantCall();
    error UnexpectedTokenAmount();
    error TokenTransferFailed();
    error InsufficientBalance();
    error PrincipalTokenNotWithdrawable();
    error NativeTransferFailed();

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event GaslessDeposit(
        address indexed user, address indexed token, address indexed executor,
        uint256 depositAmount, uint256 feeAmount, uint256 relayerFee,
        uint256 protocolFee, bytes32 authorizationNonce
    );
    event Withdrawal(address indexed user, address indexed token, uint256 amount);

    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    constructor(
        address coreAddress,
        address feeRecipient,
        uint16 feeBps,
        address[] memory supportedTokens
    ) {
        if (coreAddress == address(0) || feeRecipient == address(0)) revert InvalidAddress();
        if (feeBps > BPS) revert InvalidConfiguration();
        core = IEVVMCore(coreAddress);
        protocolFeeRecipient = feeRecipient;
        protocolFeeBps = feeBps;
        for (uint256 i; i < supportedTokens.length; ++i) {
            if (supportedTokens[i] == address(0)) revert InvalidAddress();
            supportedERC3009Token[supportedTokens[i]] = true;
        }
    }

    function computeAuthorizationNonce(
        address from, address token, uint256 depositAmount, uint256 feeAmount,
        address executor, bytes32 salt
    ) public view returns (bytes32) {
        return keccak256(abi.encode(
            NONCE_TYPEHASH, block.chainid, address(this), from, token,
            depositAmount, feeAmount, executor, salt
        ));
    }

    /// @notice Conventional deposit path remains available.
    function deposit(address token, uint256 amount) external payable nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (token == address(0)) {
            if (msg.value != amount) revert InvalidNativeValue();
        } else {
            if (msg.value != 0) revert InvalidNativeValue();
            uint256 beforeBalance = IERC20Minimal(token).balanceOf(address(this));
            _safeTransferFrom(token, msg.sender, amount);
            if (IERC20Minimal(token).balanceOf(address(this)) - beforeBalance != amount) {
                revert UnexpectedTokenAmount();
            }
        }
        core.addAmountToUser(msg.sender, token, amount);
        emit Deposit(msg.sender, token, amount);
    }

    /// @notice User authorizes deposit + fee; an active Fisher submits and pays host-chain gas.
    function depositWithAuthorization(
        address from, address token, uint256 depositAmount, uint256 feeAmount,
        address authorizedExecutor, uint256 validAfter, uint256 validBefore,
        bytes32 userSalt, uint8 v, bytes32 r, bytes32 s
    ) external nonReentrant {
        if (msg.value != 0) revert InvalidNativeValue();
        if (from == address(0) || depositAmount == 0 || feeAmount == 0) revert InvalidAmount();
        if (!supportedERC3009Token[token]) revert UnsupportedToken();
        if (token == core.getPrincipalTokenAddress()) revert PrincipalTokenNotSupported();
        if (!core.isAddressStaker(msg.sender)) revert CallerNotStaker();
        if (authorizedExecutor != address(0) && authorizedExecutor != msg.sender) {
            revert UnauthorizedExecutor();
        }

        uint256 total = depositAmount + feeAmount;
        bytes32 nonce = computeAuthorizationNonce(
            from, token, depositAmount, feeAmount, authorizedExecutor, userSalt
        );
        uint256 beforeBalance = IERC20Minimal(token).balanceOf(address(this));
        IERC3009(token).receiveWithAuthorization(
            from, address(this), total, validAfter, validBefore, nonce, v, r, s
        );
        if (IERC20Minimal(token).balanceOf(address(this)) - beforeBalance != total) {
            revert UnexpectedTokenAmount();
        }

        uint256 protocolFee = (feeAmount * protocolFeeBps) / BPS;
        uint256 relayerFee = feeAmount - protocolFee;

        // Core accepts balance credits only from its configured Treasury address.
        core.addAmountToUser(from, token, depositAmount);
        if (relayerFee != 0) core.addAmountToUser(msg.sender, token, relayerFee);
        if (protocolFee != 0) core.addAmountToUser(protocolFeeRecipient, token, protocolFee);

        emit GaslessDeposit(
            from, token, msg.sender, depositAmount, feeAmount,
            relayerFee, protocolFee, nonce
        );
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (token == core.getPrincipalTokenAddress()) revert PrincipalTokenNotWithdrawable();
        if (core.getBalance(msg.sender, token) < amount) revert InsufficientBalance();
        core.removeAmountFromUser(msg.sender, token, amount);

        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            _safeTransfer(token, msg.sender, amount);
        }
        emit Withdrawal(msg.sender, token, amount);
    }

    function _safeTransferFrom(address token, address from, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, address(this), amount)
        );
        if (!ok || (data.length != 0 && (data.length < 32 || !abi.decode(data, (bool))))) {
            revert TokenTransferFailed();
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount)
        );
        if (!ok || (data.length != 0 && (data.length < 32 || !abi.decode(data, (bool))))) {
            revert TokenTransferFailed();
        }
    }
}
