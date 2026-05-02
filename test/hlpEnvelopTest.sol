// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "forge-std/Test.sol";
contract hlpEnvelopTest is Test  {
   // Хелпер для форматирования в ETH с 3 знаками
    function _formatEther(uint256 wei_) internal pure returns (string memory) {
        uint256 whole = wei_ / 1 ether;
        uint256 frac  = (wei_ % 1 ether) / 1e14;  // 4 знака

        return string.concat(
            vm.toString(whole),
            ".",
            _padLeft(vm.toString(frac), 4)
        );
    }

    // Добавляет ведущие нули: "5" → "0005"
    function _padLeft(
        string memory s,
        uint256 targetLen
    ) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= targetLen) return s;

        bytes memory padded = new bytes(targetLen);
        uint256 pad = targetLen - b.length;

        for (uint256 i = 0; i < pad; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < b.length; i++) {
            padded[pad + i] = b[i];
        }

        return string(padded);
    }    

}