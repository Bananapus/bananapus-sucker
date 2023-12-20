// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import {BPOptimismSucker, IJBDirectory, IJBTokens, IJBToken, IERC20} from "../src/BPOptimismSucker.sol";
import "juice-contracts-v4/src/interfaces/IJBController.sol";
import "juice-contracts-v4/src/interfaces/terminal/IJBRedeemTerminal.sol";
import "juice-contracts-v4/src/libraries/JBConstants.sol";
import "juice-contracts-v4/src/libraries/JBPermissionIds.sol";
import {JBRulesetConfig} from "juice-contracts-v4/src/structs/JBRulesetConfig.sol";
import {JBFundAccessLimitGroup} from "juice-contracts-v4/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "juice-contracts-v4/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBPermissions, JBPermissionsData} from "juice-contracts-v4/src/interfaces/IJBPermissions.sol";

import {MockMessenger} from "./mocks/MockMessenger.sol";

contract BPOptimismSuckerTest is Test {
    BPOptimismSucker public suckerL1;
    BPOptimismSucker public suckerL2;

    IJBController CONTROLLER;
    IJBDirectory DIRECTORY;
    IJBTokens TOKENS;
    IJBPermissions PERMISSIONS;
    IJBRedeemTerminal ETH_TERMINAL;

    string DEPLOYMENT_JSON = "lib/juice-contracts-v4/broadcast/Deploy.s.sol/11155111/run-latest.json";

    MockMessenger _mockMessenger;

    function setUp() public {
        vm.createSelectFork("https://ethereum-sepolia.publicnode.com"); // Will start on latest block by default

        CONTROLLER = IJBController(_getDeploymentAddress(DEPLOYMENT_JSON, "JBController"));
        DIRECTORY = IJBDirectory(_getDeploymentAddress(DEPLOYMENT_JSON, "JBDirectory"));
        TOKENS = IJBTokens(_getDeploymentAddress(DEPLOYMENT_JSON, "JBTokens"));
        PERMISSIONS = IJBPermissions(_getDeploymentAddress(DEPLOYMENT_JSON, "JBPermissions"));
        ETH_TERMINAL = IJBRedeemTerminal(_getDeploymentAddress(DEPLOYMENT_JSON, "JBMultiTerminal"));

        // Configure a mock manager that mocks the OP bridge
        _mockMessenger = new MockMessenger();

        // Get the determenistic addresses for the suckers
        uint256 _nonce = vm.getNonce(address(this));
        address _suckerL1 = vm.computeCreateAddress(address(this), _nonce);
        address _suckerL2 = vm.computeCreateAddress(address(this), _nonce + 1);

        // Configure the pair of suckers
        suckerL1 = new BPOptimismSucker(_mockMessenger, DIRECTORY, TOKENS, PERMISSIONS, _suckerL2);
        suckerL2 = new BPOptimismSucker(_mockMessenger, DIRECTORY, TOKENS, PERMISSIONS, _suckerL1);
    }

    function test_MetaSuckersLinked() public {
        assertEq(suckerL1.PEER(), address(suckerL2));

        assertEq(suckerL2.PEER(), address(suckerL1));
    }

    function test_linkProjects() public {
        address _L1ProjectOwner = makeAddr("L1ProjectOwner");
        address _L2ProjectOwner = makeAddr("L2ProjectOwner");

        (uint256 _L1Project, uint256 _L2Project) = _configureAndLinkProjects(_L1ProjectOwner, _L2ProjectOwner);

        assertEq(suckerL1.acceptFromRemote(_L1Project), _L2Project);

        assertEq(suckerL2.acceptFromRemote(_L2Project), _L1Project);
    }

    function test_suck_L2toL1(uint256 _payAmount) public {
        _payAmount = _bound(_payAmount, 0.1 ether, 100_000 ether);

        address _L1ProjectOwner = makeAddr("L1ProjectOwner");
        address _L2ProjectOwner = makeAddr("L2ProjectOwner");

        // Configure the projects and suckers
        (uint256 _L1Project, uint256 _L2Project) = _configureAndLinkProjects(_L1ProjectOwner, _L2ProjectOwner);

        // Fund the user
        address _user = makeAddr("user");
        vm.deal(_user, _payAmount);

        // User pays project and receives tokens in exchange on L2
        vm.startPrank(_user);
        uint256 _receivedTokens = ETH_TERMINAL.pay{value: _payAmount}(
            _L2Project, JBConstants.NATIVE_TOKEN, _payAmount, address(_user), 0, "", bytes("")
        );

        // Give sucker allowance to spend our token
        IERC20 _l1Token = IERC20(address(TOKENS.tokenOf(_L1Project)));
        IERC20 _l2Token = IERC20(address(TOKENS.tokenOf(_L2Project)));
        _l2Token.approve(address(suckerL2), _receivedTokens);

        // Expect the L1 terminal to receive the funds
        vm.expectCall(
            address(ETH_TERMINAL),
            abi.encodeCall(
                IJBTerminal.addToBalanceOf,
                (_L1Project, JBConstants.NATIVE_TOKEN, _payAmount, false, string(""), bytes(""))
            )
        );

        // Redeem tokens on the L2 and mint them on L1, moving the backing assets with it.
        suckerL2.toRemote(_L2Project, _receivedTokens, _user, 0, true);

        // Balance should now be present on L1
        assertEq(_l1Token.balanceOf(_user), _receivedTokens);
        // User should no longer have any tokens on L2
        assertEq(_l2Token.balanceOf(_user), 0);
    }

    function _configureAndLinkProjects(address _L1ProjectOwner, address _L2ProjectOwner)
        internal
        returns (uint256 _L1Project, uint256 _L2Project)
    {
        // Deploy two projects
        _L1Project = _deployJBProject(_L1ProjectOwner, "Bananapus", "NANA");
        _L2Project = _deployJBProject(_L2ProjectOwner, "BananapusOptimism", "OPNANA");

        uint256[] memory _permissions = new uint256[](1);
        _permissions[0] = JBPermissionIds.MINT_TOKENS;

        // Grant 'MINT_TOKENS' permission to the JBSuckers of their localChains
        vm.prank(_L1ProjectOwner);
        PERMISSIONS.setPermissionsFor(
            address(_L1ProjectOwner),
            JBPermissionsData({operator: address(suckerL1), projectId: _L1Project, permissionIds: _permissions})
        );

        vm.prank(_L2ProjectOwner);
        PERMISSIONS.setPermissionsFor(
            address(_L2ProjectOwner),
            JBPermissionsData({operator: address(suckerL2), projectId: _L2Project, permissionIds: _permissions})
        );

        // Register the remote projects to each-other
        _linkProjects(_L1Project, _L2Project);
    }

    function _deployJBProject(address _owner, string memory _tokenName, string memory _tokenSymbol)
        internal
        returns (uint256 _projectId)
    {
        // IJBTerminal[] memory _terminals = new IJBTerminal[](1);
        // _terminals[0] = IJBTerminal(address(ETH_TERMINAL));

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedRate: 0,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowControllerMigration: false,
            allowSetController: false,
            holdFees: false,
            useTotalSurplusForRedemptions: false,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        // Package up ruleset configuration.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].duration = 0;
        _rulesetConfig[0].weight = 10 ** 18;
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Package up terminal configuration.
        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        address[] memory _tokens = new address[](1);
        _tokens[0] = JBConstants.NATIVE_TOKEN;
        _terminalConfigurations[0] = JBTerminalConfig({terminal: ETH_TERMINAL, tokensToAccept: _tokens});

        _projectId = CONTROLLER.launchProjectFor({
            owner: _owner,
            projectMetadata: "myIPFSHash",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        vm.prank(_owner);
        CONTROLLER.deployERC20For(_projectId, _tokenName, _tokenSymbol);
    }

    function _linkProjects(uint256 _projectIdL1, uint256 _projectIdL2) internal {
        IJBProjects _projects = DIRECTORY.PROJECTS();

        // Link the project on L1 to the project on L2
        vm.prank(_projects.ownerOf(_projectIdL1));
        suckerL1.register(_projectIdL1, _projectIdL2);

        // Link the project on L2 to the project on L1
        vm.prank(_projects.ownerOf(_projectIdL2));
        suckerL2.register(_projectIdL2, _projectIdL1);
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
