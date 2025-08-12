// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @title A sample Lottery Contract
 * @author Sumit Mazumdar
 * @notice This contract is for creating a sample lottery contract
 * @dev Implements Chainlink VRF
 */
contract Lottery {
    /* errors */
    error Lottery__SendMoreEthToParticipate();

    uint256 private immutable i_entranceFee;
    address payable[] private s_players;

    /* events */
    event PlayerEntered(address indexed player);

    constructor(uint256 entranceFee) {
        i_entranceFee = entranceFee;
    }

    function enterLottery() public payable {
        if (msg.value < i_entranceFee) {
            revert Lottery__SendMoreEthToParticipate();
        }
        s_players.push(payable(msg.sender));
        emit PlayerEntered(msg.sender);
    }

    function pickWinner() public {}

    /**
     * getter functions
     */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }
}
