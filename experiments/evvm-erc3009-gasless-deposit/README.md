# EVVM ERC-3009 Gasless Deposit — Reference Proposal

This is an independent proof of concept for an **optional gas-sponsored ERC-20 deposit path** in EVVM. It is not production-ready, audited, or an official EVVM implementation.

## Problem observed in the current code

The current \`Treasury.deposit(token, amount)\` path uses \`transferFrom\` and then calls \`Core.addAmountToUser\`. For an ERC-20 deposit, a user normally needs to approve the Treasury and submit the deposit transaction, paying the host chain's gas token.

The Core balance-credit function only accepts calls from the configured \`treasuryAddress\`. This means the proposal must be integrated into the configured Treasury (or accompanied by an intentional Core migration/authorization change); a sidecar Treasury cannot directly credit balances in an already initialized EVVM.

## Proposed flow

1. The user signs an ERC-3009 \`receiveWithAuthorization\` for \`depositAmount + feeAmount\`, with this Treasury as the recipient.
2. An active Fisher submits the authorization and pays the host-chain gas.
3. The Treasury credits \`depositAmount\` to the user's internal EVVM balance.
4. The user-authorized fee is split between the Fisher and a protocol-fee recipient, both as internal EVVM balances.
5. The ordinary deposit path remains available without this relayer fee.

This makes deposits possible without a prior ERC-20 approval or the user submitting a gas-paying transaction. The user still pays an explicit fee in the selected ERC-3009 token.

## Why ERC-3009

\`receiveWithAuthorization\` is used because the token checks that the caller is the signed recipient. The Treasury itself calls the token, so the authorization is bound to the intended receiver.

ERC-3009 signs \`from\`, \`to\`, \`value\`, validity bounds, and \`nonce\`, but it does not include EVVM-specific fields such as the net deposit, fee split, or selected Fisher. The PoC derives the ERC-3009 nonce from a structured hash containing chain ID, Treasury address, user, token, deposit amount, fee amount, optional executor, and user salt. This prevents a relayer from changing those values while reusing the signature.

## Fee model and important distinction

\`protocolFeeBps\` is the protocol's share of the user-authorized relayer fee. The remainder is credited to the executing Fisher. This is separate from EVVM Core's existing \`priorityFee\` mechanism and does not add a fee to every \`Core.pay()\` call.

The Fisher receives the relayer share in the deposited token as an EVVM internal balance. The Fisher still needs liquidity and a way to convert/withdraw that asset to the host chain's native gas token. The off-chain quote must cover expected gas, conversion costs, and a risk margin. A fee that is too low may not attract execution; a fee that is too high harms user adoption.

## Scope and constraints

- Only explicitly allowlisted ERC-3009 tokens are supported.
- Exact balance-delta checks reject fee-on-transfer behavior.
- Only active EVVM stakers can execute the relayed deposit.
- The normal deposit path is retained.
- The configured Core Treasury restriction means a new deployment or an intentional migration is required.
- EVVM's P2PSwap already has its own trading-fee model. This proposal does not duplicate or replace that fee.
- The protocol fee recipient and split are immutable in this PoC; a production version should define governance and timelock controls.
- Only tokens with correct ERC-3009 semantics and reliable \`balanceOf\` behavior should be supported.

## Test status

The Foundry test suite is included in \`test/\`. It covers the fee split, executor binding, signature parameter tampering, and replay protection. Tests have **not** been run in this environment because \`forge\` and \`solc\` are unavailable. Treat this as a reviewable PoC, not audited or deployable production code.

## Source references

- [EVVM Treasury](https://github.com/EVVM-org/testnet-Contracts/blob/main/src/contracts/treasury/Treasury.sol)
- [Core balance-credit restriction](https://github.com/EVVM-org/testnet-Contracts/blob/main/src/contracts/core/Core.sol)
- [EVVM P2PSwap fee model](https://github.com/EVVM-org/testnet-Contracts/blob/main/src/contracts/p2pSwap/P2PSwap.sol)
- [ERC-3009](https://eips.ethereum.org/EIPS/eip-3009)

## License

This experiment is licensed under the EVVM Noncommercial License v1.0. See the adjacent \`LICENSE\` file and the [full EVVM license terms](https://www.evvm.org/docs/EVVMNoncommercialLicense). Commercial use requires a separate license from MATE Labs Inc.
