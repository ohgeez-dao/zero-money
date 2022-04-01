// SPDX-License-Identifier: WTFPL

pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev A mintable ERC20 token that allows anyone to pay and distribute ZERO
///  to token holders as dividends and allows token holders to withdraw their dividends.
///  Reference: https://github.com/Roger-Wu/erc1726-dividend-paying-token/blob/master/contracts/DividendPayingToken.sol
contract ZeroMoney is ERC20 {
    using SafeCast for uint256;
    using SafeCast for int256;

    // For more discussion about choosing the value of `magnitude`,
    //  see https://github.com/ethereum/EIPs/issues/1726#issuecomment-472352728
    uint256 public constant MAGNITUDE = 2**128;
    uint256 public constant HALVING_PERIOD = 21 days;
    uint256 public constant FINAL_ERA = 60;

    address public immutable signer;
    uint256 public immutable claimDeadline;

    mapping(address => bool) public claimed;

    uint256 internal magnifiedDividendPerShare;

    // About dividendCorrection:
    // If the token balance of a `_user` is never changed, the dividend of `_user` can be computed with:
    //   `dividendOf(_user) = dividendPerShare * balanceOf(_user)`.
    // When `balanceOf(_user)` is changed (via minting/burning/transferring tokens),
    //   `dividendOf(_user)` should not be changed,
    //   but the computed value of `dividendPerShare * balanceOf(_user)` is changed.
    // To keep the `dividendOf(_user)` unchanged, we add a correction term:
    //   `dividendOf(_user) = dividendPerShare * balanceOf(_user) + dividendCorrectionOf(_user)`,
    //   where `dividendCorrectionOf(_user)` is updated whenever `balanceOf(_user)` is changed:
    //   `dividendCorrectionOf(_user) = dividendPerShare * (old balanceOf(_user)) - (new balanceOf(_user))`.
    // So now `dividendOf(_user)` returns the same value before and after `balanceOf(_user)` is changed.
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) internal withdrawnDividends;

    /// @dev This event MUST emit when an address withdraws their dividend.
    /// @param to The address which withdraws ZERO from this contract.
    /// @param amount The amount of withdrawn ZERO in wei.
    event Withdraw(address indexed to, uint256 amount);

    constructor(address _signer, uint256 _claimDeadline) ERC20("thezero.money", "ZERO") {
        signer = _signer;
        claimDeadline = _claimDeadline;
    }

    /// @notice View the amount of dividend in wei that an address can withdraw.
    /// @param account The address of a token holder.
    /// @return The amount of dividend in wei that `account` can withdraw.
    function withdrawableDividendOf(address account) public view returns (uint256) {
        return accumulativeDividendOf(account) - withdrawnDividends[account];
    }

    /// @notice View the amount of dividend in wei that an address has withdrawn.
    /// @param account The address of a token holder.
    /// @return The amount of dividend in wei that `account` has withdrawn.
    function withdrawnDividendOf(address account) public view returns (uint256) {
        return withdrawnDividends[account];
    }

    /// @notice View the amount of dividend in wei that an address has earned in total.
    /// @dev accumulativeDividendOf(account) = withdrawableDividendOf(account) + withdrawnDividendOf(account)
    /// = (magnifiedDividendPerShare * balanceOf(account) + magnifiedDividendCorrections[account]) / magnitude
    /// @param account The address of a token holder.
    /// @return The amount of dividend in wei that `account` has earned in total.
    function accumulativeDividendOf(address account) public view returns (uint256) {
        return
            ((magnifiedDividendPerShare * balanceOf(account)).toInt256() + magnifiedDividendCorrections[account])
            .toUint256() / MAGNITUDE;
    }

    function transfer(address to, uint256 amount) public override returns (bool success) {
        success = super.transfer(to, amount);

        _distribute(amount);
    }

    function _distribute(uint256 amount) private {
        uint256 _now = block.timestamp;
        uint256 era;
        if (claimDeadline < _now) {
            era = (_now - claimDeadline) / HALVING_PERIOD;
        }
        if (FINAL_ERA <= era) {
            return;
        }

        amount = amount / (era + 1);
        magnifiedDividendPerShare = magnifiedDividendPerShare + ((amount * MAGNITUDE) / totalSupply());
    }

    /// @dev Internal function that transfer tokens from one address to another.
    /// Update magnifiedDividendCorrections to keep dividends unchanged.
    /// @param from The address to transfer from.
    /// @param to The address to transfer to.
    /// @param value The amount to be transferred.
    function _transfer(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._transfer(from, to, value);

        int256 _magCorrection = (magnifiedDividendPerShare * value).toInt256();
        magnifiedDividendCorrections[from] += _magCorrection;
        magnifiedDividendCorrections[to] -= _magCorrection;
    }

    function claim(
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(!claimed[msg.sender], "ZERO: CLAIMED");
        require(block.timestamp < claimDeadline, "ZERO: EXPIRED");

        bytes32 message = keccak256(abi.encodePacked(msg.sender));
        require(ECDSA.recover(ECDSA.toEthSignedMessageHash(message), v, r, s) == signer, "ZERO: UNAUTHORIZED");

        claimed[msg.sender] = true;

        _mint(msg.sender, 1 ether);
    }

    /// @notice Withdraws dividends distributed to the sender.
    /// @dev It emits a `Withdraw` event if the amount of withdrawn ZERO is greater than 0.
    function withdrawDividend() public {
        uint256 _withdrawableDividend = withdrawableDividendOf(msg.sender);
        if (_withdrawableDividend > 0) {
            withdrawnDividends[msg.sender] += _withdrawableDividend;
            emit Withdraw(msg.sender, _withdrawableDividend);
            _mint(msg.sender, _withdrawableDividend);
        }
    }
}
