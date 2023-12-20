// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {OPMessenger} from "../../src/interfaces/OPMessenger.sol";

contract MockMessenger is OPMessenger {
    address public xDomainMessageSender;

    function sendMessage(address _target, bytes memory _message, uint32 _gasLimit) external payable {
        // Update the sender
        xDomainMessageSender = msg.sender;
        // Perform the 'crosschain' call
        (bool _success,) = _target.call{value: msg.value, gas: _gasLimit}(_message);
        require(_success);
    }
}
