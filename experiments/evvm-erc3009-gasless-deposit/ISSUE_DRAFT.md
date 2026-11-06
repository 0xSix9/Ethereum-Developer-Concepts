# GitHub Issue Draft

**Target repository:** https://github.com/EVVM-org/testnet-Contracts/issues/new

**Suggested title:** [Feature Proposal] ERC-3009 gas-sponsored deposits with Fisher/protocol fee split

---

Hi EVVM maintainers,

I reviewed the current Treasury/Core flow and would like to propose an **optional ERC-3009 gas-sponsored ERC-20 deposit path with an explicit relayer/protocol fee split**.

## Current behavior

- \`Treasury.deposit(token, amount)\` uses ERC-20 \`transferFrom\` and then credits the user's internal balance through \`Core.addAmountToUser\`.
- For an ERC-20 deposit, a user normally needs an allowance and must submit the deposit transaction with the host chain's native gas token.
- \`Core.addAmountToUser\` only accepts calls from the configured \`treasuryAddress\`.

References:
- [EVVM Treasury](https://github.com/EVVM-org/testnet-Contracts/blob/main/src/contracts/treasury/Treasury.sol)
- [Core balance-credit restriction](https://github.com/EVVM-org/testnet-Contracts/blob/main/src/contracts/core/Core.sol)
- [ERC-3009](https://eips.ethereum.org/EIPS/eip-3009)

## Proposal

Add an **opt-in** \`depositWithAuthorization\` path to the configured Treasury:

1. The user signs ERC-3009 \`receiveWithAuthorization\` for \`depositAmount + feeAmount\`, with this Treasury as the signed recipient.
2. An active Fisher submits the authorization and pays the host-chain gas.
3. The Treasury credits only \`depositAmount\` to the user's internal EVVM balance.
4. The signed fee is split between the executing Fisher and a configured protocol-fee recipient, both credited as internal EVVM balances.
5. The current deposit path remains available for users who prefer to submit and pay for their own deposit.

The user still pays a disclosed fee in the ERC-3009 token; the improvement is that the user does not need a prior approval transaction or the host chain's native gas token to make the deposit.

The PoC derives the ERC-3009 nonce from a structured hash of chain ID, Treasury, user, token, net deposit amount, fee amount, optional authorized Fisher, and a user salt. This binds EVVM-specific fee parameters to the standard authorization and prevents a relayer from changing the split or amounts. Only allowlisted ERC-3009 tokens are accepted, and exact balance-delta checks reject fee-on-transfer behavior.

## Why this may be useful

- Improves onboarding for users who hold USDC or another supported ERC-3009 token but have no native gas token.
- Gives Fishers a predictable, user-authorized relayer fee in the deposited asset.
- Adds an optional, direct protocol-fee stream to the configured recipient without imposing a new fee on every \`Core.pay()\` call.
- Keeps the feature opt-in, so the existing deposit route remains unchanged.

This is separate from the current Core \`priorityFee\` and does not replace or duplicate the P2PSwap trading-fee mechanism.

## Integration constraint

This cannot simply be deployed as a sidecar beside an already initialized EVVM: \`Core.addAmountToUser\` only accepts the configured \`treasuryAddress\`, and \`initializeSystemContracts\` configures that address once. The implementation therefore needs to be integrated into the configured Treasury for a new EVVM instance, or paired with an explicit migration/Core authorization design for existing instances.

Also, the Fisher's reward would be an internal balance in the deposited token (for example, USDC), not native gas. The relayer economics must account for withdrawal/conversion liquidity and host-chain gas volatility.

## Reference implementation

I prepared a non-production reference implementation and Foundry tests here:

[ERC-3009 gasless-deposit PoC branch](https://github.com/0xSix9/Ethereum-Developer-Concepts/tree/proposal/evvm-erc3009-gasless-deposit/experiments/evvm-erc3009-gasless-deposit)

The Foundry tests currently pass in GitHub Actions: 5 passed, 0 failed (Solidity 0.8.24). They cover fee splitting, replay protection, executor binding, amount tampering, non-staker rejection, unsupported-token rejection, and expired authorizations. CI run: https://github.com/0xSix9/Ethereum-Developer-Concepts/actions/runs/42299440620.

These tests use a mock Core and mock ERC-3009 token; they do not establish end-to-end compatibility with a deployed EVVM instance or production readiness. This remains an unaudited reference PoC.

Would the team consider this direction? In particular, would you prefer it as an extension of the current Treasury, a separate Treasury implementation for new deployments, or a migration/authorized-credit path for existing EVVM instances?
