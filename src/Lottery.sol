// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title A sample Lottery Contract
 * @author Sumit Mazumdar
 * @notice This contract is for creating a sample lottery contract
 * @dev Implements Chainlink VRF
 */
contract Lottery is VRFConsumerBaseV2Plus {
    /* errors */
    error Lottery__SendMoreEthToParticipate();
    error Lottery__TransferFailed();
    error Lottery__LotteryNotOpened();
    error Lottery__UpkeepNotNeeded(uint256 balance, uint256 playersLength, uint256 raffleState);

    /* type declarations */
    enum LotteryState {
        OPEN, // 0
        CALCULATING // 1

    }

    /* state variables */
    uint16 private constant REQUEST_CONFIRMATION = 3;
    uint32 private constant RANDOM_WORDS = 1;
    uint256 private immutable i_entranceFee;
    // @dev The duration of the lottery in seconds
    uint256 private immutable i_interval;
    bytes32 private immutable i_keyHash;
    uint256 private immutable i_subscriptionId;
    uint32 private i_callbackGasLimit;
    address payable[] private s_players;
    uint256 private s_lastTimeStamp;
    address private s_recentWinner;
    LotteryState private s_lotteryState;

    /* events */
    event PlayerEntered(address indexed player);
    event WinnerPicked(address indexed player);
    event RequestLotteryWinner(uint256 indexed requestId);

    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint256 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_entranceFee = entranceFee;
        i_interval = interval;
        i_keyHash = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;

        s_lastTimeStamp = block.timestamp;
        s_lotteryState = LotteryState.OPEN;
    }

    function enterLottery() external payable {
        if (msg.value < i_entranceFee) {
            revert Lottery__SendMoreEthToParticipate();
        }
        s_players.push(payable(msg.sender));
        emit PlayerEntered(msg.sender);

        if (s_lotteryState != LotteryState.OPEN) {
            revert Lottery__LotteryNotOpened();
        }
    }

    // When should the winner be picked
    /**
     * @dev This is the function chain link will call to see if
     * the lottery is ready to have a winner picked.
     * The following should be true in order for upkeepNeeded to be true:
     * 1. The time interval has passed between raffle runs
     * 2. The lottery is open
     * 3. The contract has eth (has players)
     * 4. Implicitly, your subscription has link
     * @param - ignored
     * @return upkeepNeeded - true , if it's time to restart the lottery
     * @return - ignored
     */
    function checkUpkeep(bytes memory /* checkdata */ )
        public
        view
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        bool timeHasPassed = (block.timestamp - s_lastTimeStamp) >= i_interval;
        bool isOpen = s_lotteryState == LotteryState.OPEN;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;
        upkeepNeeded = timeHasPassed && isOpen && hasBalance && hasPlayers;
        return (upkeepNeeded, "");
    }

    function performUpKeep(bytes calldata /* performData */ ) external {
        // check to see if enough time has passed

        // `this.checkUpkeep("")` is needed since `checkUpkeep` uses calldata (external call).
        // If defined with memory, we could call it internally without `this.`
        (bool upKeepNeeded,) = checkUpkeep("");
        if (!upKeepNeeded) {
            revert Lottery__UpkeepNotNeeded(address(this).balance, s_players.length, uint256(s_lotteryState));
        }

        s_lotteryState = LotteryState.CALCULATING;

        // used from chainlink vrf doc
        // Will revert if subscription is not set and funded.
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATION,
                callbackGasLimit: i_callbackGasLimit,
                numWords: RANDOM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    // Set nativePayment to true to pay for VRF requests with Sepolia ETH instead of LINK
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        emit RequestLotteryWinner(requestId);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal virtual override {
        // Effects (Internal Contract State)
        uint256 indexOfWinner = randomWords[0] % s_players.length;

        address payable recentWinner = s_players[indexOfWinner];
        s_recentWinner = recentWinner;
        s_lotteryState = LotteryState.OPEN;
        // reset the player arr
        s_players = new address payable[](0);

        s_lastTimeStamp = block.timestamp;

        // Interactions (External Contracts Interactions)
        (bool success,) = recentWinner.call{value: address(this).balance}("");
        if (!success) {
            revert Lottery__TransferFailed();
        }

        emit WinnerPicked(s_recentWinner);
    }

    /**
     * getter functions
     */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getLotteryState() external view returns (LotteryState) {
        return s_lotteryState;
    }

    function getPlayer(uint256 indexOfPlayer) external view returns (address) {
        return s_players[indexOfPlayer];
    }

    function getLatestTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getRecentWinner() public view returns (address) {
        return s_recentWinner;
    }

    function getPlayerNumber() external view returns (uint256) {
        return s_players.length;
    }
}
