// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {BPOptimismSucker, IJBDirectory, IJBTokens, IJBPermissions} from "../src/BPOptimismSucker.sol";
import {OPMessenger} from "../src/interfaces/OPMessenger.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract DeployScript is Script {
    // Sepolia config
    string CHAIN_A_RPC;
    OPMessenger constant CHAIN_A_OP_MESSENGER = OPMessenger(0x58Cc85b8D04EA49cC6DBd3CbFFd00B4B8D6cb3ef);
    string CHAIN_A_DEPLOYMENT_JSON = "lib/juice-contracts-v4/broadcast/Deploy.s.sol/11155111/run-latest.json";

    // OP Sepolia config
    string CHAIN_B_RPC;
    OPMessenger constant CHAIN_B_OP_MESSENGER = OPMessenger(0x4200000000000000000000000000000000000007);
    string CHAIN_B_DEPLOYMENT_JSON = "lib/juice-contracts-v4/broadcast/Deploy.s.sol/11155420/run-latest.json";

    function setUp() public {
        CHAIN_A_RPC = vm.envString("CHAIN_A_RPC");
        CHAIN_B_RPC = vm.envString("CHAIN_B_RPC");

        if (bytes(CHAIN_A_RPC).length == 0) {
            revert("CHAIN_A_RPC not set.");
        }

        if (bytes(CHAIN_B_RPC).length == 0) {
            revert("CHAIN_B_RPC not set.");
        }
    }

    function run() public {
        // Get the nonces for the two chains.
        uint256 _chainA = vm.createSelectFork(CHAIN_A_RPC);
        uint256 _chainANonce = vm.getNonce(msg.sender);

        uint256 _chainB = vm.createSelectFork(CHAIN_B_RPC);
        uint256 _chainBNonce = vm.getNonce(msg.sender);

        if (_chainANonce != _chainANonce) {
            console2.log("WARNING: Nonces do not match between chains.");
        }

        // Compute the addresses for the suckers.
        address _precomputeChainASucker = vm.computeCreateAddress(msg.sender, _chainANonce);
        address _precomputeChainBSucker = vm.computeCreateAddress(msg.sender, _chainBNonce);

        // Deploy the suckers.
        vm.selectFork(_chainA);
        vm.broadcast();
        BPOptimismSucker _suckerA = new BPOptimismSucker(
            CHAIN_A_OP_MESSENGER,
            IJBDirectory(_getDeploymentAddress(CHAIN_A_DEPLOYMENT_JSON, "JBDirectory")),
            IJBTokens(_getDeploymentAddress(CHAIN_A_DEPLOYMENT_JSON, "JBTokens")),
            IJBPermissions(_getDeploymentAddress(CHAIN_A_DEPLOYMENT_JSON, "JBPermissions")),
            _precomputeChainBSucker
        );

        vm.selectFork(_chainB);
        vm.broadcast();
        BPOptimismSucker _suckerB = new BPOptimismSucker(
            CHAIN_B_OP_MESSENGER,
            IJBDirectory(_getDeploymentAddress(CHAIN_B_DEPLOYMENT_JSON, "JBDirectory")),
            IJBTokens(_getDeploymentAddress(CHAIN_B_DEPLOYMENT_JSON, "JBTokens")),
            IJBPermissions(_getDeploymentAddress(CHAIN_B_DEPLOYMENT_JSON, "JBPermissions")),
            _precomputeChainASucker
        );

        // Verify the suckers were deployed to the predetermined addresses.
        if (address(_suckerA) != _precomputeChainASucker) {
            revert("Sucker A was not deployed to the correct address.");
        }
        if (address(_suckerB) != _precomputeChainBSucker) {
            revert("Sucker B was not deployed to the correct address.");
        }

        console2.log("Suckers deployed.");
        console2.log("Sucker A: ", Strings.toHexString(uint160(address(_suckerA)), 20));
        console2.log("Sucker B: ", Strings.toHexString(uint160(address(_suckerB)), 20));
    }

    /**
     * @notice Get the address of a contract that was deployed by the Deploy script.
     *     @dev Reverts if the contract was not found.
     *     @param _path The path to the deployment file.
     *     @param _contractName The name of the contract to get the address of.
     *     @return The address of the contract.
     */
    function _getDeploymentAddress(string memory _path, string memory _contractName) internal view returns (address) {
        string memory _deploymentJson = vm.readFile(_path);
        uint256 _nOfTransactions = stdJson.readStringArray(_deploymentJson, ".transactions").length;

        for (uint256 i = 0; i < _nOfTransactions; i++) {
            string memory _currentKey = string.concat(".transactions", "[", Strings.toString(i), "]");
            string memory _currentContractName =
                stdJson.readString(_deploymentJson, string.concat(_currentKey, ".contractName"));

            if (keccak256(abi.encodePacked(_currentContractName)) == keccak256(abi.encodePacked(_contractName))) {
                return stdJson.readAddress(_deploymentJson, string.concat(_currentKey, ".contractAddress"));
            }
        }

        revert(
            string.concat("Could not find contract with name '", _contractName, "' in deployment file '", _path, "'")
        );
    }
}
