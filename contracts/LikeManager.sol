// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract LikeManager {
    mapping(address => mapping(uint256 => bool)) public liked;
    mapping(uint256 => uint256) public totalLikes;

    event Liked(address indexed user, uint256 indexed tokenId);
    event Unliked(address indexed user, uint256 indexed tokenId);

    function like(uint256 tokenId) external {
        require(!liked[msg.sender][tokenId], "Already liked");
        liked[msg.sender][tokenId] = true;
        totalLikes[tokenId]++;
        emit Liked(msg.sender, tokenId);
    }

    function unlike(uint256 tokenId) external {
        require(liked[msg.sender][tokenId], "Not liked yet");
        liked[msg.sender][tokenId] = false;
        totalLikes[tokenId]--;
        emit Unliked(msg.sender, tokenId);
    }

    function isLiked(address user, uint256 tokenId) public view returns (bool) {
        return liked[user][tokenId];
    }
}
