// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployLottery} from "../../script/DeployLottery.s.sol";
import {Lottery} from "../../src/Lottery.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {console2} from "forge-std/console2.sol";
import {LinkToken} from "../mocks/LinkToken.sol";

contract LotteryTest is Test {
    Lottery public lottery;
    HelperConfig public helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint32 callbackGasLimit;
    uint256 subscriptionId;
    LinkToken link;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_PLAYER_BALANCE = 10 ether;
    uint256 public constant LINK_BALANCE = 100 ether;

    event PlayerEntered(address indexed player);
    event WinnerPicked(address indexed player);

    uint256 constant LOCAL_CHAIN_ID = 31337;

    function setUp() external {
        DeployLottery deployer = new DeployLottery();
        (lottery, helperConfig) = deployer.deployContract();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        entranceFee = config.entranceFee;
        interval = config.interval;
        vrfCoordinator = config.vrfCoordinatorV2_5;
        gasLane = config.gasLane;
        callbackGasLimit = config.callbackGasLimit;
        subscriptionId = config.subscriptionId;

        vm.deal(PLAYER, STARTING_PLAYER_BALANCE);

        link = LinkToken(config.link);

        vm.startPrank(msg.sender);
        if (block.chainid == LOCAL_CHAIN_ID) {
            link.mint(msg.sender, LINK_BALANCE);
            VRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(subscriptionId, LINK_BALANCE);
        }
        link.approve(vrfCoordinator, LINK_BALANCE);
        vm.stopPrank();
    }

    function testLotteryInitializesInOpenState() public view {
        assert(lottery.getLotteryState() == Lottery.LotteryState.OPEN);
    }

    function testRaffleRevertWhenyouDontPayEnough() public {
        // Arrange
        vm.prank(PLAYER);
        // Act / Assert
        vm.expectRevert(Lottery.Lottery__SendMoreEthToParticipate.selector);
        lottery.enterLottery();
    }

    function testRaffleRecordsPlayerWhenTheyEnter() public {
        vm.prank(PLAYER);
        lottery.enterLottery{value: entranceFee}();
        address playerRecorded = lottery.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEnteringLotteryEmitsEvent() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(lottery));
        emit PlayerEntered(PLAYER);
        lottery.enterLottery{value: entranceFee}();
    }

    function testDontAllowPlayersToEnterWhileLotteryIsCalculating() public {
        vm.prank(PLAYER);
        lottery.enterLottery{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        lottery.performUpKeep("");

        vm.expectRevert(Lottery.Lottery__LotteryNotOpened.selector);
        vm.prank(PLAYER);
        lottery.enterLottery{value: entranceFee}();
    }

    function testCheckUpkeepReturnsFalseIfIthasNoBalance() public {
        vm.prank(PLAYER);
        // warp forward in time
        vm.warp(block.timestamp + interval + 1);
        // roll forward a block
        vm.roll(block.number + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Lottery.Lottery__UpkeepNotNeeded.selector,
                0, // balance
                0, // numPlayers
                0 // lotteryState
            )
        );
        lottery.performUpKeep("");
        (bool upkeepNeeded,) = lottery.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue() public {
        vm.prank(PLAYER);
        lottery.enterLottery{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        lottery.performUpKeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Lottery.LotteryState lotteryState = lottery.getLotteryState();

        vm.prank(PLAYER);
        lottery.enterLottery{value: entranceFee}();
        currentBalance = currentBalance + entranceFee;
        numPlayers = 1;

        vm.expectRevert(
            abi.encodeWithSelector(Lottery.Lottery__UpkeepNotNeeded.selector, currentBalance, numPlayers, lotteryState)
        );
        lottery.performUpKeep("");
    }

    modifier raffleEntered() {
        vm.prank(PLAYER);
        lottery.enterLottery{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function testPerformUpkeepUpdateLotteryStateAndEmitsRequestId() public raffleEntered {
        vm.recordLogs();
        lottery.performUpKeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        assert(uint256(requestId) > 0);
        assert(uint256(requestId) == 1);
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(uint256 randomRequestId) public raffleEntered {
        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(lottery));
    }

    function testFulfillrandomWordsPicksAWinnerResetAndSendsMoney() public raffleEntered skipFork {
        uint256 additionalEntrants = 3; // 4 total
        uint256 startingIndex = 1;
        address expectedWinner = address(1);

        for (uint256 i = startingIndex; i < startingIndex + additionalEntrants; i++) {
            address newPlayer = address(uint160(i));
            hoax(newPlayer, 1 ether);
            lottery.enterLottery{value: entranceFee}();
        }
        uint256 startingTimeStamp = lottery.getLatestTimeStamp();
        console2.log("start lottery :", startingTimeStamp);
        uint256 winnerStartingBal = expectedWinner.balance;

        vm.recordLogs();
        lottery.performUpKeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        console2.log("Lottery balance before fulfill:", address(lottery).balance);
        console2.log("Entrance fee:", entranceFee);
        console2.log("Players count:", lottery.getPlayerNumber());
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(lottery));

        address recentWinner = lottery.getRecentWinner();
        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        uint256 winnerBal = recentWinner.balance;
        uint256 endingTimeStamp = lottery.getLatestTimeStamp();
        uint256 prize = entranceFee * (additionalEntrants + 1);
        console2.log("Expected prize:", prize);
        assertEq(recentWinner, expectedWinner);
        assert(uint256(lotteryState) == 0);
        assert(winnerBal == winnerStartingBal + prize);
        console2.log("End lottery :", endingTimeStamp);
        assert(endingTimeStamp > startingTimeStamp);
    }
}
