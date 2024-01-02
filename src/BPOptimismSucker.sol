// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {OPMessenger} from "./interfaces/OPMessenger.sol";

import {IJBDirectory} from "juice-contracts-v4/src/interfaces/IJBDirectory.sol";
import {IJBController} from "juice-contracts-v4/src/interfaces/IJBController.sol";
import {IJBTokens, IJBToken} from "juice-contracts-v4/src/interfaces/IJBTokens.sol";
import {IJBTerminal} from "juice-contracts-v4/src/interfaces/terminal/IJBTerminal.sol";
import {IJBRedeemTerminal} from "juice-contracts-v4/src/interfaces/terminal/IJBRedeemTerminal.sol";

import {BPSuckerData, BPSuckQueueItem} from "./structs/BPSuckerData.sol";
import {JBConstants} from "juice-contracts-v4/src/libraries/JBConstants.sol";
import {JBPermissioned, IJBPermissions} from "juice-contracts-v4/src/abstract/JBPermissioned.sol";
import {JBPermissionIds} from "juice-contracts-v4/src/libraries/JBPermissionIds.sol";
import {IERC20} from "juice-contracts-v4/src/JBMultiTerminal.sol";

/// @notice A contract that sucks tokens from one chain to another.
/// @dev This implementation is designed to be deployed on two chains that are connected by an OP bridge.
contract BPOptimismSucker is JBPermissioned {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//
    error NOT_PEER();
    error INVALID_REMOTE();
    error INVALID_AMOUNT();
    error REQUIRE_ISSUED_TOKEN();
    error BENEFICIARY_NOT_ALLOWED();

    //*********************************************************************//
    // ---------------------- public stored properties ------------------- //
    //*********************************************************************//

    /// @notice what ID does the local project recognize as its remote ID.
    mapping(uint256 _localProjectId => uint256 _remoteProjectId) public acceptFromRemote;

    mapping(uint256 _localProjectId => mapping(address _token => BPSuckerData _queue)) queue;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The messenger in use to send messages between the local and remote sucker.
    OPMessenger public immutable OPMESSENGER;

    /// @notice The Juicebox Directory
    IJBDirectory public immutable DIRECTORY;

    /// @notice The Juicebox Tokenstore
    IJBTokens public immutable TOKENS;

    /// @notice The peer sucker on the remote chain.
    address public immutable PEER;

    /// @notice The maximum number of sucks that can get batched.
    uint256 constant MAX_BATCH_SIZE = 6;

    /// @notice The amount of gas the basic xchain call will use.
    uint32 constant MESSENGER_BASE_GAS_LIMIT = 500_000;

    /// @notice the amount of gas that each queue item is allowed to use.
    uint32 constant MESSENGER_QUEUE_ITEM_GAS_LIMIT = 100_000;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//
    constructor(
        OPMessenger _messenger,
        IJBDirectory _directory,
        IJBTokens _tokens,
        IJBPermissions _permissions,
        address _peer
    ) JBPermissioned(_permissions) {
        OPMESSENGER = _messenger;
        DIRECTORY = _directory;
        TOKENS = _tokens;
        PEER = _peer;
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Send to the remote project.
    /// @notice _localProjectId the Id of the project to move the tokens for.
    /// @notice _projectTokenAmount the amount of tokens to move.
    /// @notice _beneficiary the recipient of the tokens on the remote chain.
    /// @notice _minRedeemedTokens the minimum amount of assets that gets moved.
    /// @notice _forceSend whether or not to force the send, even if the queue is not full.
    function toRemote(
        uint256 _localProjectId,
        uint256 _projectTokenAmount,
        address _beneficiary,
        uint256 _minRedeemedTokens,
        bool _forceSend
    ) external {
        // Make sure that the remote project was configured.
        uint256 _remoteProjectId = acceptFromRemote[_localProjectId];
        if (_remoteProjectId == 0) {
            revert INVALID_REMOTE();
        }

        // Make sure the beneficiary is not the zero address, as this would revert when minting on the remote chain.
        if (_beneficiary == address(0)) {
            revert BENEFICIARY_NOT_ALLOWED();
        }

        // Get the terminal we will use to redeem the tokens.
        IJBRedeemTerminal _terminal =
            IJBRedeemTerminal(address(DIRECTORY.primaryTerminalOf(_localProjectId, JBConstants.NATIVE_TOKEN)));

        // Get the token for the project.
        IERC20 _projectToken = IERC20(address(TOKENS.tokenOf(_localProjectId)));
        if (address(_projectToken) == address(0)) {
            revert REQUIRE_ISSUED_TOKEN();
        }

        // Transfer the tokens to this contract.
        _projectToken.transferFrom(msg.sender, address(this), _projectTokenAmount);

        // Approve the terminal.
        _projectToken.approve(address(_terminal), _projectTokenAmount);

        // Perform the redemption.
        uint256 _balanceBefore = address(this).balance;
        uint256 _redemptionTokenAmount = _terminal.redeemTokensOf(
            address(this),
            _localProjectId,
            JBConstants.NATIVE_TOKEN,
            _projectTokenAmount,
            _minRedeemedTokens,
            payable(address(this)),
            bytes("")
        );

        // Sanity check to make sure we actually received the reported amount.
        // Prevents a malicious terminal from reporting a higher amount than it actually sent.
        assert(_redemptionTokenAmount == address(this).balance - _balanceBefore);

        // Queue the item.
        _queueItem(
            _localProjectId, _remoteProjectId, _projectTokenAmount, _redemptionTokenAmount, _beneficiary, _forceSend
        );
    }

    /// @notice Receive from the remote project.
    /// @param _localProjectId the ID on this chain.
    /// @param _remoteProjectId the ID on the remote chain.
    /// @param _redemptionTokenAmount the amount of assets being moved.
    /// @param _items the items being moved.
    function fromRemote(
        uint256 _localProjectId,
        uint256 _remoteProjectId,
        uint256 _redemptionTokenAmount,
        BPSuckQueueItem[] calldata _items
    ) external payable {
        // Make sure that the message came from our peer.
        if (msg.sender != address(OPMESSENGER) || OPMESSENGER.xDomainMessageSender() != PEER) {
            revert NOT_PEER();
        }

        // Make sure that the project that was redeemed remotely has permission to do so.
        if (acceptFromRemote[_localProjectId] != _remoteProjectId) {
            revert INVALID_REMOTE();
        }

        // Sanity check.
        if (_redemptionTokenAmount != msg.value) {
            revert INVALID_AMOUNT();
        }

        // Get the terminal of the project.
        IJBTerminal _terminal = DIRECTORY.primaryTerminalOf(_localProjectId, JBConstants.NATIVE_TOKEN);

        // Add the redeemed funds to the local terminal.
        _terminal.addToBalanceOf{value: _redemptionTokenAmount}(
            _localProjectId, JBConstants.NATIVE_TOKEN, _redemptionTokenAmount, false, string(""), bytes("")
        );

        for (uint256 _i = 0; _i < _items.length;) {
            // Mint to the beneficiary.
            // TODO: try catch this call, so that one reverting mint won't revert the entire queue
            // TODO: Bulk mint here and then send the tokens to the beneficiaries might be more effecient.
            IJBController(address(DIRECTORY.controllerOf(_localProjectId))).mintTokensOf(
                _localProjectId, _items[_i].tokensRedeemed, _items[_i].beneficiary, "", false
            );

            unchecked {
                ++_i;
            }
        }
    }

    /// @notice Register a remote projectId as the peer of a local projectId.
    /// @param _localProjectId the project Id on this chain.
    /// @param _remoteProjectId the project Id on the remote chain (or '0' to disable).
    function register(uint256 _localProjectId, uint256 _remoteProjectId) external {
        // Access control.
        _requirePermissionFrom(
            DIRECTORY.PROJECTS().ownerOf(_localProjectId), _localProjectId, JBPermissionIds.QUEUE_RULESETS
        );

        acceptFromRemote[_localProjectId] = _remoteProjectId;
    }

    /// @notice used to receive the redemption ETH.
    receive() external payable {}

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    function _queueItem(
        uint256 _localProjectId,
        uint256 _remoteProjectId,
        uint256 _projectTokenAmount,
        uint256 _redemptionTokenAmount,
        address _beneficiary,
        bool _forceSend
    ) internal {
        // Store the queued item
        BPSuckerData storage _queue = queue[_localProjectId][JBConstants.NATIVE_TOKEN];
        _queue.redemptionAmount += _redemptionTokenAmount;
        _queue.items.push(BPSuckQueueItem({beneficiary: _beneficiary, tokensRedeemed: _projectTokenAmount}));

        // Check if we should work the queue or if we only needed to append this suck to the queue.
        if (_forceSend || _queue.items.length == MAX_BATCH_SIZE) {
            _workQueue(_localProjectId, _remoteProjectId, JBConstants.NATIVE_TOKEN);
        }
    }

    /// @notice Works a specific queue, sending the sucks to the peer on the remote chain.
    /// @param _localProjectId the projectID on this chain.
    /// @param _remoteProjectId the projectID on the remote chain.
    /// @param _token the queue of the token being worked.
    function _workQueue(uint256 _localProjectId, uint256 _remoteProjectId, address _token) internal {
        // Load the queue.
        BPSuckerData memory _queue = queue[_localProjectId][_token];

        // Clear them from storage
        delete queue[_localProjectId][_token];

        // Calculate the needed gas limit for this specific queue.
        uint32 _gasLimit = MESSENGER_BASE_GAS_LIMIT + uint32(_queue.items.length * MESSENGER_QUEUE_ITEM_GAS_LIMIT);

        // Send the messenger to the peer with the redeemed ETH.
        OPMESSENGER.sendMessage{value: _queue.redemptionAmount}(
            PEER,
            abi.encodeWithSelector(
                BPOptimismSucker.fromRemote.selector,
                _remoteProjectId,
                _localProjectId,
                _queue.redemptionAmount,
                _queue.items
            ),
            _gasLimit
        );
    }
}
