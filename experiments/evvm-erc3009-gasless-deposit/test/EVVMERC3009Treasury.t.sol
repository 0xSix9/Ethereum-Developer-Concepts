// SPDX-License-Identifier: EVVM-NONCOMMERCIAL-1.0
pragma solidity ^0.8.24;

import {
    EVVMERC3009Treasury,
    IEVVMCore,
    IERC20Minimal,
    IERC3009
} from "../src/EVVMERC3009Treasury.sol";

interface Vm {
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function prank(address sender) external;
    function expectRevert(bytes4 selector) external;
    function warp(uint256 timestamp) external;
}

contract MockCore is IEVVMCore {
    address public treasury;
    address private immutable principalToken;
    mapping(address => bool) private stakers;
    mapping(address => mapping(address => uint256)) public balances;

    constructor(address principalToken_) { principalToken = principalToken_; }
    function setTreasury(address value) external { treasury = value; }
    function setStaker(address account, bool active) external { stakers[account] = active; }

    function addAmountToUser(address user, address token, uint256 amount) external override {
        require(msg.sender == treasury, "NOT_TREASURY");
        balances[user][token] += amount;
    }

    function removeAmountFromUser(address user, address token, uint256 amount) external override {
        require(msg.sender == treasury, "NOT_TREASURY");
        balances[user][token] -= amount;
    }

    function getBalance(address user, address token) external view override returns (uint256) {
        return balances[user][token];
    }

    function getPrincipalTokenAddress() external view override returns (address) {
        return principalToken;
    }

    function isAddressStaker(address user) external view override returns (bool) {
        return stakers[user];
    }
}

contract MockERC3009Token is IERC20Minimal, IERC3009 {
    string public constant name = "Mock USD";
    string public constant version = "2";
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant TRANSFER_TYPEHASH =
        keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");
    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    error CallerIsNotPayee();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error InvalidAuthorization();

    constructor() {
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)),
            block.chainid, address(this)
        ));
    }

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function receiveWithAuthorization(
        address from, address to, uint256 value, uint256 validAfter,
        uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s
    ) external override {
        if (msg.sender != to) revert CallerIsNotPayee();
        if (block.timestamp < validAfter || block.timestamp > validBefore) revert AuthorizationExpired();
        if (authorizationState[from][nonce]) revert AuthorizationAlreadyUsed();

        bytes32 structHash = keccak256(abi.encode(
            TRANSFER_TYPEHASH, from, to, value, validAfter, validBefore, nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (ecrecover(digest, v, r, s) != from) revert InvalidAuthorization();

        authorizationState[from][nonce] = true;
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}

contract EVVMERC3009TreasuryTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant USER_KEY = 0xA11CE;
    uint256 private constant DEPOSIT = 1_000e6;
    uint256 private constant FEE = 10e6;
    uint256 private constant PROTOCOL_BPS = 2_000;

    address private user;
    address private fisher = address(0xBEEF);
    address private otherFisher = address(0xCAFE);
    address private protocol = address(0xFEE1);
    MockCore private core;
    MockERC3009Token private token;
    EVVMERC3009Treasury private treasury;

    function setUp() public {
        user = vm.addr(USER_KEY);
        core = new MockCore(address(0xB0B));
        token = new MockERC3009Token();
        address[] memory supported = new address[](1);
        supported[0] = address(token);
        treasury = new EVVMERC3009Treasury(address(core), protocol, uint16(PROTOCOL_BPS), supported);
        core.setTreasury(address(treasury));
        core.setStaker(fisher, true);
        core.setStaker(otherFisher, true);
        token.mint(user, DEPOSIT + FEE);
    }

    function testFeeSplitAndReplayProtection() public {
        bytes32 salt = keccak256("first-deposit");
        uint256 validAfter = block.timestamp;
        uint256 validBefore = block.timestamp + 1 days;
        bytes32 nonce = treasury.computeAuthorizationNonce(
            user, address(token), DEPOSIT, FEE, address(0), salt
        );
        (uint8 v, bytes32 r, bytes32 s) = _sign(DEPOSIT + FEE, validAfter, validBefore, nonce);

        vm.prank(fisher);
        treasury.depositWithAuthorization(
            user, address(token), DEPOSIT, FEE, address(0),
            validAfter, validBefore, salt, v, r, s
        );

        uint256 protocolFee = (FEE * PROTOCOL_BPS) / 10_000;
        uint256 relayerFee = FEE - protocolFee;
        require(core.balances(user, address(token)) == DEPOSIT, "USER_CREDIT");
        require(core.balances(fisher, address(token)) == relayerFee, "FISHER_CREDIT");
        require(core.balances(protocol, address(token)) == protocolFee, "PROTOCOL_CREDIT");
        require(token.balanceOf(address(treasury)) == DEPOSIT + FEE, "BACKING");

        vm.expectRevert(MockERC3009Token.AuthorizationAlreadyUsed.selector);
        vm.prank(fisher);
        treasury.depositWithAuthorization(
            user, address(token), DEPOSIT, FEE, address(0),
            validAfter, validBefore, salt, v, r, s
        );
    }

    function testExecutorBindingAndAmountTampering() public {
        bytes32 salt = keccak256("bound-executor");
        uint256 validAfter = block.timestamp;
        uint256 validBefore = block.timestamp + 1 days;
        bytes32 nonce = treasury.computeAuthorizationNonce(
            user, address(token), DEPOSIT, FEE, fisher, salt
        );
        (uint8 v, bytes32 r, bytes32 s) = _sign(DEPOSIT + FEE, validAfter, validBefore, nonce);

        vm.expectRevert(EVVMERC3009Treasury.UnauthorizedExecutor.selector);
        vm.prank(otherFisher);
        treasury.depositWithAuthorization(
            user, address(token), DEPOSIT, FEE, fisher,
            validAfter, validBefore, salt, v, r, s
        );

        vm.expectRevert(MockERC3009Token.InvalidAuthorization.selector);
        vm.prank(fisher);
        treasury.depositWithAuthorization(
            user, address(token), DEPOSIT - 1, FEE + 1, fisher,
            validAfter, validBefore, salt, v, r, s
        );
    }

    function testNonStakerCannotRelay() public {
        address outsider = address(0xD00D);
        vm.expectRevert(EVVMERC3009Treasury.CallerNotStaker.selector);
        vm.prank(outsider);
        treasury.depositWithAuthorization(
            user, address(token), DEPOSIT, FEE, address(0),
            block.timestamp, block.timestamp + 1 days,
            keccak256("non-staker"), 27, bytes32(0), bytes32(0)
        );
    }

    function testUnsupportedTokenRejected() public {
        MockERC3009Token unsupported = new MockERC3009Token();
        vm.expectRevert(EVVMERC3009Treasury.UnsupportedToken.selector);
        vm.prank(fisher);
        treasury.depositWithAuthorization(
            user, address(unsupported), DEPOSIT, FEE, address(0),
            block.timestamp, block.timestamp + 1 days,
            keccak256("unsupported-token"), 27, bytes32(0), bytes32(0)
        );
    }

    function testExpiredAuthorizationRejected() public {
        vm.warp(3 days);
        uint256 validAfter = block.timestamp - 2 days;
        uint256 validBefore = block.timestamp - 1;
        bytes32 salt = keccak256("expired-authorization");
        bytes32 nonce = treasury.computeAuthorizationNonce(
            user, address(token), DEPOSIT, FEE, address(0), salt
        );
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            DEPOSIT + FEE, validAfter, validBefore, nonce
        );

        vm.expectRevert(MockERC3009Token.AuthorizationExpired.selector);
        vm.prank(fisher);
        treasury.depositWithAuthorization(
            user, address(token), DEPOSIT, FEE, address(0),
            validAfter, validBefore, salt, v, r, s
        );
    }

    function _sign(
        uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce
    ) private returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(
            token.TRANSFER_TYPEHASH(), user, address(treasury),
            value, validAfter, validBefore, nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(USER_KEY, digest);
    }
}
