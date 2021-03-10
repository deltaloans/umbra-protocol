// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract Umbra is Ownable {
  using SafeMath for uint256;

  // =========================================== Events ============================================

  /// @notice Emitted when a payment is sent
  event Announcement(
    address indexed receiver, // stealth address
    uint256 amount, // funds
    address indexed token, // token address or ETH placeholder
    bytes32 pkx, // ephemeral public key x coordinate
    bytes32 ciphertext // encrypted entropy and payload extension
  );

  /// @notice Emitted when a token is withdrawn
  event TokenWithdrawal(
    address indexed receiver, // stealth address
    address indexed acceptor, // destination of funds
    uint256 amount, // funds
    address indexed token // token address
  );

  // ======================================= State variables =======================================

  /// @notice Version string for this Umbra contract
  string public constant version = "1";

  /// @notice Chain identifier where this contract is deployed; set in constructor
  uint256 public immutable chainId;

  /// @dev Placeholder address used to identify transfer of native ETH
  address constant ETH_TOKEN_PLACHOLDER = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /// @notice An ETH amount that must be sent alongside each payment; used as an anti-spam measure
  uint256 public toll;

  /// @notice A privileged address, set by the admin, that can sweep all collected ETH tolls
  address public tollCollector;

  /// @notice The address where ETH funds are sent when collected by the tollCollector
  address payable public tollReceiver;

  /// @notice Token payments pending withdrawal; stealth address => token address => amount
  mapping(address => mapping(address => uint256)) public tokenPayments;

  // ======================================= Setup & Admin ========================================

  /**
   * @param _toll Amount of ETH required per send
   * @param _tollCollector Address that can sweep collected funds
   * @param _tollReceiver Address that receives collected funds
   */
  constructor(
    uint256 _toll,
    address _tollCollector,
    address payable _tollReceiver
  ) public {
    toll = _toll;
    tollCollector = _tollCollector;
    tollReceiver = _tollReceiver;

    uint256 _chainId;

    assembly {
      _chainId := chainid()
    }

    chainId = _chainId;
  }

  /**
   * @notice Admin only function to update the toll
   * @param _newToll New ETH toll in wei
   */
  function setToll(uint256 _newToll) external onlyOwner {
    toll = _newToll;
  }

  /**
   * @notice Admin only function to update the toll collector
   * @param _newTollCollector New address which has fund sweeping privileges
   */
  function setTollCollector(address _newTollCollector) external onlyOwner {
    tollCollector = _newTollCollector;
  }

  /**
   * @notice Admin only function to update the toll receiver
   * @param _newTollReceiver New address which receives collected funds
   */
  function setTollReceiver(address payable _newTollReceiver) external onlyOwner {
    tollReceiver = _newTollReceiver;
  }

  /**
   * @notice Function only the toll collector can call to sweep funds to the toll receiver
   */
  function collectTolls() external {
    require(msg.sender == tollCollector, "Umbra: Not toll collector");
    tollReceiver.transfer(address(this).balance);
  }

  // ======================================= Send =================================================

  /**
   * @notice Send and announce ETH payment to a stealth address
   * @param _receiver Stealth address receiving the payment
   * @param _tollCommitment Exact toll the sender is paying; should equal contract toll;
   * the committment is used to prevent frontrunning attacks by the owner;
   * see https://github.com/ScopeLift/umbra-protocol/issues/54 for more information
   * @param _pkx X-coordinate of the ephemeral public key used to encrypt the payload
   * @param _ciphertext Encrypted entropy (used to generated the stealth address) and payload extension
   */
  function sendEth(
    address payable _receiver,
    uint256 _tollCommitment,
    bytes32 _pkx, // ephemeral public key x coordinate
    bytes32 _ciphertext
  ) external payable {
    require(_tollCommitment == toll, "Umbra: Invalid or outdated toll commitment");
    require(msg.value > toll, "Umbra: Must pay more than the toll");

    uint256 amount = msg.value.sub(toll);
    emit Announcement(_receiver, amount, ETH_TOKEN_PLACHOLDER, _pkx, _ciphertext);

    _receiver.transfer(amount);
  }

  /**
   * @notice Send and announce an ERC20 payment to a stealth address
   * @param _receiver Stealth address receiving the payment
   * @param _tokenAddr Address of the ERC20 token being sent
   * @param _amount Amount of the token to send, in its own base units
   * @param _pkx X-coordinate of the ephemeral public key used to encrypt the payload
   * @param _ciphertext Encrypted entropy (used to generated the stealth address) and payload extension
   */
  function sendToken(
    address _receiver,
    address _tokenAddr,
    uint256 _amount,
    bytes32 _pkx, // ephemeral public key x coordinate
    bytes32 _ciphertext
  ) external payable {
    require(msg.value == toll, "Umbra: Must pay the exact toll");
    require(tokenPayments[_receiver][_tokenAddr] == 0, "Umbra: Cannot send more tokens to stealth address");

    tokenPayments[_receiver][_tokenAddr] = _amount;
    emit Announcement(_receiver, _amount, _tokenAddr, _pkx, _ciphertext);

    SafeERC20.safeTransferFrom(IERC20(_tokenAddr), msg.sender, address(this), _amount);
  }

  // ======================================= Withdraw =============================================

  /**
   * @notice Withdraw an ERC20 token payment sent to a stealth address
   * @dev This method must be directly called by the stealth address
   * @param _acceptor Address where withdrawn funds should be sent
   * @param _tokenAddr Address of the ERC20 token being withdrawn
   */
  function withdrawToken(address _acceptor, address _tokenAddr) external {
    uint256 amount = tokenPayments[msg.sender][_tokenAddr];

    require(amount > 0, "Umbra: No tokens available for withdrawal");

    delete tokenPayments[msg.sender][_tokenAddr];
    emit TokenWithdrawal(msg.sender, _acceptor, amount, _tokenAddr);

    SafeERC20.safeTransfer(IERC20(_tokenAddr), _acceptor, amount);
  }

  /**
   * @notice Withdraw an ERC20 token payment on behalf of a stealth address via signed authorization
   * @param _stealthAddr The stealth address whose token balance will be withdrawn
   * @param _acceptor Address where withdrawn funds should be sent
   * @param _tokenAddr Address of the ERC20 token being withdrawn
   * @param _sponsor Address which is compensated for submitting the withdrawal tx
   * @param _sponsorFee Amount of the token to pay to the transfer
   * @param _v ECDSA signature component: Parity of the `y` coordinate of point `R`
   * @param _r ECDSA signature component: x-coordinate of `R`
   * @param _s ECDSA signature component: `s` value of the signature
   */
  function withdrawTokenOnBehalf(
    address _stealthAddr,
    address _acceptor,
    address _tokenAddr,
    address _sponsor,
    uint256 _sponsorFee,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external {
    uint256 _amount = tokenPayments[_stealthAddr][_tokenAddr];

    // also protects from underflow
    require(_amount > _sponsorFee, "Umbra: No balance to withdraw or fee exceeds balance");

    bytes32 _digest =
      keccak256(
        abi.encodePacked("\x19Ethereum Signed Message:\n32",
          keccak256(
            abi.encode(
              chainId,
              version,
              _acceptor,
              _tokenAddr,
              _sponsor,
              _sponsorFee
            )
          )
        )
      );

    address _recoveredAddress = ecrecover(_digest, _v, _r, _s);

    require(_recoveredAddress != address(0) && _recoveredAddress == _stealthAddr, "Umbra: Invalid Signature");

    uint256 _withdrawalAmount = _amount - _sponsorFee;
    delete tokenPayments[_stealthAddr][_tokenAddr];
    emit TokenWithdrawal(_stealthAddr, _acceptor, _withdrawalAmount, _tokenAddr);

    SafeERC20.safeTransfer(IERC20(_tokenAddr), _acceptor, _withdrawalAmount);
    SafeERC20.safeTransfer(IERC20(_tokenAddr), _sponsor, _sponsorFee);
  }
}
