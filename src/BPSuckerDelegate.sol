// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import "src/BPOptimismSucker.sol";
import {JBConstants} from "juice-contracts-v4/src/libraries/JBConstants.sol";
import {IJBPrices} from "juice-contracts-v4/src/interfaces/IJBPrices.sol";
import {IJBPayHook, JBAfterPayRecordedContext} from "juice-contracts-v4/src/interfaces/IJBPayHook.sol";
import {JBRuleset} from "juice-contracts-v4/src/structs/JBRuleset.sol";
import {IJBRulesets} from "juice-contracts-v4/src/interfaces/IJBRulesets.sol";
import {JBRulesetMetadataResolver} from "juice-contracts-v4/src/libraries/JBRulesetMetadataResolver.sol";
import {
    IJBRulesetDataHook,
    JBBeforePayRecordedContext,
    JBBeforeRedeemRecordedContext,
    JBPayHookSpecification,
    JBRedeemHookSpecification
} from "juice-contracts-v4/src/interfaces/IJBRulesetDataHook.sol";

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {mulDiv} from "juice-contracts-v4/lib/prb-math/src/Common.sol";

contract BPSuckerDelegate is BPOptimismSucker, IJBRulesetDataHook, IJBPayHook {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    struct EncodedMetadata {
        IJBRedeemTerminal terminal;
        uint256 remoteProjectId;
        uint256 tokenAmount;
        address beneficiary;
    }

    error NOT_ALLOWED();
    error INVALID_REMOTE_PROJECT_ID();

    /// @notice The contract storing and managing project rulesets.
    IJBRulesets public immutable RULESETS;

    /// @notice The contract that exposes price feeds.
    IJBPrices public immutable PRICES;

    constructor(
        IJBPrices _prices,
        IJBRulesets _rulesets,
        OPMessenger _messenger,
        IJBDirectory _directory,
        IJBTokens _tokens,
        IJBPermissions _permissions,
        address _peer
    ) BPOptimismSucker(_messenger, _directory, _tokens, _permissions, _peer) {
        PRICES = _prices;
        RULESETS = _rulesets;
    }

    /// @notice The data calculated before a payment is recorded in the terminal store. This data is provided to the
    /// terminal's `pay(...)` transaction.
    /// @param context The context passed to this data hook by the `pay(...)` function as a `JBBeforePayRecordedContext`
    /// struct.
    /// @return weight The new `weight` to use, overriding the ruleset's `weight`.
    /// @return hookSpecifications The amount and data to send to pay hooks instead of adding to the terminal's balance.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        uint256 _remoteProjectId = acceptFromRemote[context.projectId];
        if (
            context.amount.token != JBConstants.NATIVE_TOKEN
            // We only support the native asset (for now).
            // The remote project was not configured.
            || _remoteProjectId == 0
            // Check if the terminal supports the redeem terminal interface.
            || !ERC165Checker.supportsInterface(address(context.terminal), type(IJBRedeemTerminal).interfaceId)
        ) {
            // In these cases we don't do anything.
            return (context.weight, new JBPayHookSpecification[](0));
        }

        // We return zero weight, so that we can do the mint on the remote chain.
        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] = JBPayHookSpecification({
            hook: IJBPayHook(address(this)),
            amount: 0,
            metadata: ''
        });

        return (0, hookSpecifications);
    }

    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable {
        // Check that the caller is a terminal.
        if (!DIRECTORY.isTerminalOf(context.projectId, IJBTerminal(msg.sender))) revert NOT_ALLOWED();

        // Should be valid.
        uint256 _remoteProjectId = acceptFromRemote[context.projectId];
        if(_remoteProjectId == 0) revert INVALID_REMOTE_PROJECT_ID();

        // Get the projects ruleset.
        JBRuleset memory _ruleset = RULESETS.getRulesetOf(context.projectId, context.rulesetId);

        // Calculate the amount of tokens that would be minted for this payment.
        uint256 _weightRatio = context.amount.currency == _ruleset.baseCurrency()
            ? 10 ** context.amount.decimals
            : PRICES.pricePerUnitOf({
                projectId: context.projectId,
                pricingCurrency: context.amount.currency,
                unitCurrency: _ruleset.baseCurrency(),
                decimals: context.amount.decimals
            });

        uint256 _tokenCount = mulDiv(context.amount.value, context.weight, _weightRatio);

        // Get the projects token.
        IERC20 _projectToken = IERC20(address(TOKENS.tokenOf(context.projectId)));

        // Get this contract balance.
        uint256 _projectTokenBalanceBefore = _projectToken.balanceOf(address(this));

        // Mint tokens to this address.
        uint256 _beneficiaryTokenCount = IJBController(address(DIRECTORY.controllerOf(context.projectId))).mintTokensOf({
            projectId: context.projectId,
            tokenCount: _tokenCount,
            beneficiary: address(this),
            memo: "",
            useReservedRate: true
        });

        // Sanity check: we should have received the tokens.
        assert(_beneficiaryTokenCount == _projectToken.balanceOf(address(this)) - _projectTokenBalanceBefore);

        // Perform the redemption.
        uint256 _nativeBalanceBefore = address(this).balance;
        uint256 _reclaimAmount = IJBRedeemTerminal(msg.sender).redeemTokensOf(
            address(this),
            context.projectId,
            JBConstants.NATIVE_TOKEN,
            _beneficiaryTokenCount,
            0,
            payable(address(this)),
            ""
        );

        // Sanity check: we received the native asset.
        assert(address(this).balance == _nativeBalanceBefore + _reclaimAmount);

        // Sanity check: we redeemed the project tokens.
        assert(_projectToken.balanceOf(address(this)) == _projectTokenBalanceBefore);

        // Add the reclaim amount to the messenger queue.
        _queueItem({
            _localProjectId: context.projectId,
            _remoteProjectId: _remoteProjectId,
            _projectTokenAmount: _beneficiaryTokenCount,
            _redemptionTokenAmount: _reclaimAmount,
            _beneficiary: context.beneficiary,
            _forceSend: false
        });
    }

    /// @notice We don't do anything on redemption.
    function beforeRedeemRecordedWith(JBBeforeRedeemRecordedContext calldata context)
        external
        pure
        returns (uint256 , JBRedeemHookSpecification[] memory)
    {
        return (context.reclaimAmount.value, new JBRedeemHookSpecification[](0));
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        // TODO: Implement
    }
}
