// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./TransferVerifier.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IComplianceVerifier {
    function verifyProof(
        uint[2] memory _pA,
        uint[2][2] memory _pB,
        uint[2] memory _pC,
        uint[6] memory _publicSignals
    ) external view returns (bool);
}

interface IPoseidon {
    function poseidon(uint256[2] memory input) external pure returns (uint256);
}

/**
 * @title TornadoStyleShieldedPoolERC20
 * @dev Privacy-preserving pool for ERC20 tokens (inspired by Tornado Cash)
 */
contract TornadoStyleShieldedPoolERC20 {
    // Constants
    uint256 public FEE_RATE; // Adjustable fee rate, 1% = 10000 basis points
    uint256 public constant FEE_BASE = 10000;
    uint256 public constant TREE_DEPTH = 20;
    uint256 public constant ROOT_HISTORY_SIZE = 30;
    uint256 public constant ZERO_VALUE = 0;

    // Immutable variables
    Groth16Verifier public immutable verifier;
    IComplianceVerifier public immutable complianceVerifier;
    IPoseidon public immutable poseidon;
    IERC20 public immutable token;

    // State variables
    mapping(bytes32 => bool) public nullifierHashes;
    mapping(bytes32 => bool) public commitments;
    mapping(bytes32 => uint256) public commitmentAmounts;
    mapping(bytes32 => address) public commitmentOwners;
    // Totals tracking
    uint256 public totalAmountIn;
    uint256 public totalAmountOut;
    uint256 public totalFee;
    mapping(uint32 => uint256) public leaves;
    mapping(uint256 => uint32) public commitmentIndex;
    struct ComplianceRecord {
        bytes32 commitment;
        bytes32 nullifierHash;
        bytes32 amountHash;
        uint256 timestamp;
        bool verified;
    }
    mapping(uint256 => ComplianceRecord) public complianceRecords;
    mapping(bytes32 => uint256[]) public commitmentComplianceRequests;
    uint32 public currentRootIndex = 0;
    uint32 public nextIndex = 0;
    mapping(uint256 => uint256) public filledSubtrees;
    mapping(uint256 => uint256) public roots;
    mapping(uint256 => uint256) public zeros;
    mapping(address => bool) public operators;
    uint256 public immutable relayerFee;
    bool public isDepositsEnabled = true;
    bool public isWithdrawalsEnabled = true;
    address public governance;
    bool public isEmergencyMode = false;
    address public feeAddress;

    // Events
    event Deposit(
        bytes32 indexed commitment,
        uint32 leafIndex,
        uint256 timestamp,
        address owner
    );
    event Withdrawal(
        address to,
        bytes32 nullifierHash,
        address indexed relayer,
        uint256 fee
    );
    event WithdrawWithChange(
        address indexed recipient,
        bytes32 indexed nullifierHash,
        uint256 withdrawAmount,
        bytes32 outCommit1,
        bytes32 outCommit2
    );
    event ComplianceSubmitted(
        uint256 indexed requestId,
        bytes32 indexed commitment,
        bytes32 nullifierHash,
        bytes32 amountHash
    );
    event OperatorUpdated(address indexed operator, bool status);
    event EmergencyModeUpdated(bool enabled);

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == governance, "Only governance");
        _;
    }
    modifier onlyOperator() {
        require(operators[msg.sender], "Only operator");
        _;
    }
    modifier depositsEnabled() {
        require(isDepositsEnabled && !isEmergencyMode, "Deposits disabled");
        _;
    }
    modifier withdrawalsEnabled() {
        require(
            isWithdrawalsEnabled && !isEmergencyMode,
            "Withdrawals disabled"
        );
        _;
    }

    // Constructor
    constructor(
        address _verifier,
        address _poseidon,
        uint256 _relayerFee,
        address _governance,
        address _complianceVerifier,
        address _feeAddress,
        address _token,
        uint256 _feeRate
    ) {
        require(_relayerFee < 10000, "Fee too high");
        require(_governance != address(0), "Invalid governance");
        require(_poseidon != address(0), "Invalid poseidon address");
        require(_token != address(0), "Invalid token address");
        require(_feeRate < 10000, "Fee rate too high");
        verifier = Groth16Verifier(_verifier);
        poseidon = IPoseidon(_poseidon);
        complianceVerifier = IComplianceVerifier(_complianceVerifier);
        relayerFee = _relayerFee;
        governance = _governance;
        feeAddress = _feeAddress;
        token = IERC20(_token);
        FEE_RATE = _feeRate;
        _initializeTree();
    }

    function _initializeTree() internal {
        zeros[0] = ZERO_VALUE;
        for (uint32 i = 1; i < TREE_DEPTH; i++) {
            zeros[i] = _hashLeftRight(zeros[i - 1], zeros[i - 1]);
        }
        roots[0] = zeros[TREE_DEPTH - 1];
    }

    // Deposit ERC20 tokens
    function deposit(
        bytes32 _commitment,
        uint256 _amount
    ) external depositsEnabled {
        require(_amount > 0, "Must deposit some tokens");
        require(_commitment != bytes32(0), "Invalid commitment");
        require(!commitments[_commitment], "Commitment already exists");
        require(nextIndex != 2 ** TREE_DEPTH, "Merkle tree is full");
        require(
            token.transferFrom(msg.sender, address(this), _amount),
            "Token transfer failed"
        );
        commitments[_commitment] = true;
        commitmentAmounts[_commitment] = _amount;
        commitmentOwners[_commitment] = msg.sender;
        uint32 insertedIndex = _insert(_commitment);
        leaves[insertedIndex] = uint256(_commitment);
        commitmentIndex[uint256(_commitment)] = insertedIndex;
        totalAmountIn += _amount;
        emit Deposit(_commitment, insertedIndex, block.timestamp, msg.sender);
    }

    function _insert(bytes32 _leaf) internal returns (uint32 index) {
        uint32 _nextIndex = nextIndex;
        require(_nextIndex != 2 ** TREE_DEPTH, "Merkle tree is full");
        uint32 currentIndex = _nextIndex;
        uint256 currentLevelHash = uint256(_leaf);
        uint256 left;
        uint256 right;
        for (uint32 i = 0; i < TREE_DEPTH; i++) {
            if (currentIndex % 2 == 0) {
                left = currentLevelHash;
                right = zeros[i];
                filledSubtrees[i] = currentLevelHash;
            } else {
                left = filledSubtrees[i];
                right = currentLevelHash;
            }
            currentLevelHash = _hashLeftRight(left, right);
            currentIndex /= 2;
        }
        uint32 newRootIndex = uint32(
            (currentRootIndex + 1) % ROOT_HISTORY_SIZE
        );
        currentRootIndex = newRootIndex;
        roots[newRootIndex] = currentLevelHash;
        nextIndex = _nextIndex + 1;
        return _nextIndex;
    }

    // Withdraw ERC20 tokens
    function withdraw(
        uint[8] calldata _proof,
        bytes32 _root,
        bytes32 _nullifierHash,
        uint256 _outBlinding1,
        bytes32 _outCommit2,
        address _recipient,
        address _relayer,
        uint256 _fee,
        uint256 _amount
    ) external withdrawalsEnabled {
        require(_fee <= _amount, "Fee exceeds deposit amount");
        require(!nullifierHashes[_nullifierHash], "Note already spent");
        require(_isValidRoot(_root), "Cannot find your merkle root");
        uint256 _outCommit1 = poseidon.poseidon([_amount, _outBlinding1]);
        uint256[4] memory publicInputs = [
            uint256(_nullifierHash),
            _outCommit1,
            uint256(_outCommit2),
            uint256(_root)
        ];
        require(
            verifier.verifyProof(
                [_proof[0], _proof[1]],
                [[_proof[2], _proof[3]], [_proof[4], _proof[5]]],
                [_proof[6], _proof[7]],
                publicInputs
            ),
            "Invalid withdraw proof"
        );
        nullifierHashes[_nullifierHash] = true;
        uint256 __fee = (FEE_RATE * _amount) / FEE_BASE;
        uint256 withdrawAmount = _amount - __fee;
        totalAmountOut += withdrawAmount;
        totalFee += __fee;
        if (__fee > 0) {
            require(token.transfer(feeAddress, __fee), "Fee transfer failed");
        }
        require(
            token.transfer(_recipient, withdrawAmount),
            "Recipient transfer failed"
        );
        emit Withdrawal(_recipient, _nullifierHash, _relayer, __fee);
    }

    function withdrawWithChange(
        uint[8] calldata _proof,
        bytes32 _root,
        bytes32 _nullifierHash,
        uint256 _outBlinding1,
        bytes32 _outCommit2,
        address _recipient,
        address _relayer,
        uint256 _fee,
        uint256 _amount
    ) external withdrawalsEnabled {
        require(_fee <= _amount, "Fee cannot exceed deposit amount");
        require(!nullifierHashes[_nullifierHash], "Note already spent");
        require(_isValidRoot(_root), "Cannot find your merkle root");
        uint256 _outCommit1 = poseidon.poseidon([_amount, _outBlinding1]);
        uint256[4] memory publicInputs = [
            uint256(_nullifierHash),
            _outCommit1,
            uint256(_outCommit2),
            uint256(_root)
        ];
        require(
            verifier.verifyProof(
                [_proof[0], _proof[1]],
                [[_proof[2], _proof[3]], [_proof[4], _proof[5]]],
                [_proof[6], _proof[7]],
                publicInputs
            ),
            "Invalid withdraw proof"
        );
        nullifierHashes[_nullifierHash] = true;
        if (_outCommit2 != bytes32(0)) {
            require(
                !commitments[_outCommit2],
                "Change commitment already exists"
            );
            commitments[_outCommit2] = true;
            commitmentOwners[_outCommit2] = msg.sender;
            uint32 insertedIndex = _insert(_outCommit2);
            leaves[insertedIndex] = uint256(_outCommit2);
            commitmentIndex[uint256(_outCommit2)] = insertedIndex;
            emit Deposit(
                _outCommit2,
                insertedIndex,
                block.timestamp,
                msg.sender
            );
        }
        uint256 __fee = (FEE_RATE * _amount) / FEE_BASE;
        uint256 finalWithdrawAmount = _amount - __fee;
        totalAmountOut += finalWithdrawAmount;
        totalFee += __fee;
        if (__fee > 0) {
            require(token.transfer(feeAddress, __fee), "Fee transfer failed");
        }
        require(
            token.transfer(_recipient, finalWithdrawAmount),
            "Recipient transfer failed"
        );
        emit Withdrawal(_recipient, _nullifierHash, _relayer, __fee);
        emit WithdrawWithChange(
            _recipient,
            _nullifierHash,
            _amount,
            bytes32(_outCommit1),
            _outCommit2
        );
    }

    function _isValidRoot(bytes32 _root) internal view returns (bool) {
        uint256 root = uint256(_root);
        if (root == 0) return false;
        if (roots[currentRootIndex] == root) return true;
        uint32 _currentRootIndex = currentRootIndex;
        for (uint32 i = 1; i < ROOT_HISTORY_SIZE; i++) {
            if (
                roots[
                    (_currentRootIndex + ROOT_HISTORY_SIZE - i) %
                        ROOT_HISTORY_SIZE
                ] == root
            ) {
                return true;
            }
        }
        return false;
    }

    function relayWithdraw(
        uint[8] calldata _proof,
        bytes32 _root,
        bytes32 _nullifierHash,
        uint256 _outBlinding1,
        bytes32 _outCommit2,
        address _recipient,
        uint256 _fee,
        uint256 _amount
    ) external onlyOperator withdrawalsEnabled {
        require(_fee <= (_amount * relayerFee) / 10000, "Fee too high");
        this.withdraw(
            _proof,
            _root,
            _nullifierHash,
            _outBlinding1,
            _outCommit2,
            _recipient,
            msg.sender,
            _fee,
            _amount
        );
    }

    function verifyCompliance(
        uint[8] calldata _proof,
        bytes32 _merkleRoot,
        uint256 _requestId,
        bytes32 _commitment,
        bytes32 _nullifierHash,
        bytes32 _amountHash,
        uint256 _isValid
    ) external view returns (bool) {
        require(
            address(complianceVerifier) != address(0),
            "Compliance verifier not set"
        );
        require(_isValidRoot(_merkleRoot), "Invalid merkle root");

        // New circuit structure: all 6 are outputs (no public inputs)
        uint256[6] memory publicInputs = [
            uint256(_merkleRoot), // Public output 0: merkleRoot
            _requestId, // Public output 1: requestId
            uint256(_commitment), // Public output 2: commitment
            uint256(_nullifierHash), // Public output 3: nullifierHash
            uint256(_amountHash), // Public output 4: amountHash
            _isValid // Public output 5: isValid
        ];

        return
            complianceVerifier.verifyProof(
                [_proof[0], _proof[1]],
                [[_proof[2], _proof[3]], [_proof[4], _proof[5]]],
                [_proof[6], _proof[7]],
                publicInputs
            );
    }

    function submitComplianceProof(
        uint[8] calldata _proof,
        bytes32 _merkleRoot,
        uint256 _requestId,
        bytes32 _commitment,
        bytes32 _nullifierHash,
        bytes32 _amountHash
    ) external returns (bool) {
        require(
            address(complianceVerifier) != address(0),
            "Compliance verifier not set"
        );
        require(_isValidRoot(_merkleRoot), "Invalid merkle root");
        require(
            complianceRecords[_requestId].timestamp == 0,
            "Request already processed"
        );
        require(commitments[_commitment], "Commitment not found in pool");

        // New circuit structure: all 6 are outputs (no public inputs)
        uint256[6] memory publicInputs = [
            uint256(_merkleRoot), // Public output 0: merkleRoot
            _requestId, // Public output 1: requestId
            uint256(_commitment), // Public output 2: commitment
            uint256(_nullifierHash), // Public output 3: nullifierHash
            uint256(_amountHash), // Public output 4: amountHash
            1 // Public output 5: isValid (always 1 for valid proofs)
        ];

        bool verified = complianceVerifier.verifyProof(
            [_proof[0], _proof[1]],
            [[_proof[2], _proof[3]], [_proof[4], _proof[5]]],
            [_proof[6], _proof[7]],
            publicInputs
        );

        if (verified) {
            // Store compliance record
            complianceRecords[_requestId] = ComplianceRecord({
                commitment: _commitment,
                nullifierHash: _nullifierHash,
                amountHash: _amountHash,
                timestamp: block.timestamp,
                verified: true
            });

            // Add to commitment's compliance history
            commitmentComplianceRequests[_commitment].push(_requestId);

            emit ComplianceSubmitted(
                _requestId,
                _commitment,
                _nullifierHash,
                _amountHash
            );
            return true;
        }

        return false;
    }

    function hasComplianceRecord(
        bytes32 _commitment
    ) external view returns (bool) {
        return commitmentComplianceRequests[_commitment].length > 0;
    }

    function getComplianceRecord(
        uint256 _requestId
    )
        external
        view
        returns (
            bytes32 commitment,
            bytes32 nullifierHash,
            bytes32 amountHash,
            uint256 timestamp,
            bool verified
        )
    {
        ComplianceRecord memory record = complianceRecords[_requestId];
        return (
            record.commitment,
            record.nullifierHash,
            record.amountHash,
            record.timestamp,
            record.verified
        );
    }

    function getComplianceRequests(
        bytes32 _commitment
    ) external view returns (uint256[] memory) {
        return commitmentComplianceRequests[_commitment];
    }

    /**
     * @dev Get compliance info for audit purposes (governance only)
     * @param _commitment The commitment to audit
     */
    function getComplianceInfo(
        bytes32 _commitment
    )
        external
        view
        onlyGovernance
        returns (uint256 amount, uint32 leafIndex, bool exists)
    {
        exists = commitments[_commitment];
        if (exists) {
            amount = commitmentAmounts[_commitment];
            leafIndex = commitmentIndex[uint256(_commitment)];
        }
    }

    /**
     * @dev Get zero hash at level
     */
    function getZeroHash(uint32 _level) external view returns (uint256) {
        return zeros[_level];
    }

    function getLastRoot() external view returns (uint256) {
        return roots[currentRootIndex];
    }

    /**
     * @dev Check if nullifier is used
     */
    function isSpent(bytes32 _nullifierHash) external view returns (bool) {
        return nullifierHashes[_nullifierHash];
    }

    /**
     * @dev Check if commitment exists
     */
    function isKnownRoot(bytes32 _root) external view returns (bool) {
        return _isValidRoot(_root);
    }

    /**
     * @dev Get the deposit amount for a commitment
     */
    function getCommitmentAmount(
        bytes32 _commitment
    ) external view returns (uint256) {
        return commitmentAmounts[_commitment];
    }

    function updateOperator(
        address _operator,
        bool _status
    ) external onlyGovernance {
        operators[_operator] = _status;
        emit OperatorUpdated(_operator, _status);
    }

    /**
     * @dev Toggle deposits
     */
    function toggleDeposits() external onlyGovernance {
        isDepositsEnabled = !isDepositsEnabled;
    }

    function toggleWithdrawals() external onlyGovernance {
        isWithdrawalsEnabled = !isWithdrawalsEnabled;
    }

    /**
     * @dev Update fee address
     */
    function setFeeAddress(address newFeeAddress) external onlyGovernance {
        require(newFeeAddress != address(0), "Invalid fee address");
        feeAddress = newFeeAddress;
    }

    /**
     * @dev Update fee rate (basis points)
     */
    function setFeeRate(uint256 newFeeRate) external onlyGovernance {
        require(newFeeRate < 10000, "Fee rate too high");
        FEE_RATE = newFeeRate;
    }

    /**
     * @dev Emergency stop
     */
    function setEmergencyMode(bool _enabled) external onlyGovernance {
        isEmergencyMode = _enabled;
        emit EmergencyModeUpdated(_enabled);
    }

    /**
     * @dev Transfer governance
     */
    function transferGovernance(
        address _newGovernance
    ) external onlyGovernance {
        require(_newGovernance != address(0), "Invalid governance");
        governance = _newGovernance;
    }

    function getTreeSize() external view returns (uint32) {
        return nextIndex;
    }

    function getTreeCapacity() external pure returns (uint32) {
        return uint32(2 ** TREE_DEPTH);
    }

    function getCurrentRoot() external view returns (uint256) {
        return roots[currentRootIndex];
    }

    function getCurrentRootIndex() external view returns (uint32) {
        return currentRootIndex;
    }

    function getNextLeafIndex() external view returns (uint32) {
        return nextIndex;
    }

    function getRoots() external view returns (uint256[] memory) {
        uint256[] memory _roots = new uint256[](ROOT_HISTORY_SIZE);
        for (uint32 i = 0; i < ROOT_HISTORY_SIZE; i++) {
            _roots[i] = roots[i];
        }
        return _roots;
    }

    function getFilledSubtrees() external view returns (uint256[] memory) {
        uint256[] memory _subtrees = new uint256[](TREE_DEPTH);
        for (uint32 i = 0; i < TREE_DEPTH; i++) {
            _subtrees[i] = filledSubtrees[i];
        }
        return _subtrees;
    }

    function getContractBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function isDepositsDisabled() external view returns (bool) {
        return !isDepositsEnabled || isEmergencyMode;
    }

    function isWithdrawalsDisabled() external view returns (bool) {
        return !isWithdrawalsEnabled || isEmergencyMode;
    }

    function getLeaf(uint32 _index) external view returns (uint256) {
        require(_index < nextIndex, "Leaf index out of bounds");
        return leaves[_index];
    }

    // ...existing compliance, utility, governance, and view functions can be copied from the ETH version...

    function _hashLeftRight(
        uint256 _left,
        uint256 _right
    ) internal view returns (uint256) {
        return poseidon.poseidon([_left, _right]);
    }

    function getMerkleProof(
        uint32 _leafIndex
    )
        external
        view
        returns (uint256[] memory pathElements, uint256[] memory pathIndices)
    {
        require(_leafIndex < nextIndex, "Leaf index out of bounds");
        require(nextIndex > 0, "No deposits in tree");

        pathElements = new uint256[](TREE_DEPTH);
        pathIndices = new uint256[](TREE_DEPTH);

        uint32 currentIndex = _leafIndex;

        for (uint32 level = 0; level < TREE_DEPTH; level++) {
            bool isRightChild = currentIndex % 2 == 1;
            pathIndices[level] = isRightChild ? 1 : 0;

            if (level == 0) {
                // Leaf level - find sibling leaf
                uint32 siblingIndex = isRightChild
                    ? currentIndex - 1
                    : currentIndex + 1;
                if (siblingIndex < nextIndex) {
                    pathElements[level] = leaves[siblingIndex];
                } else {
                    pathElements[level] = zeros[0];
                }
            } else {
                // Internal levels - reconstruct sibling by following _insert logic
                uint32 siblingIndex = isRightChild
                    ? currentIndex - 1
                    : currentIndex + 1;
                pathElements[level] = _computeNodeHash(siblingIndex, level);
            }

            currentIndex /= 2;
        }

        return (pathElements, pathIndices);
    }

    function _computeNodeHash(
        uint32 nodeIndex,
        uint32 level
    ) internal view returns (uint256) {
        if (level == 0) {
            // Leaf level
            if (nodeIndex < nextIndex) {
                return leaves[nodeIndex];
            } else {
                return zeros[0];
            }
        }

        // Internal node - check if this entire subtree is empty
        uint32 subtreeSize = uint32(1 << level);
        uint32 subtreeStart = nodeIndex * subtreeSize;

        if (subtreeStart >= nextIndex) {
            // Entire subtree is empty
            return zeros[level];
        }

        // Subtree has some elements, need to compute hash recursively
        uint32 leftChild = nodeIndex * 2;
        uint32 rightChild = leftChild + 1;

        uint256 leftHash = _computeNodeHash(leftChild, level - 1);
        uint256 rightHash = _computeNodeHash(rightChild, level - 1);

        return _hashLeftRight(leftHash, rightHash);
    }

    function debugMerkleProof(
        uint32 _leafIndex
    )
        external
        view
        returns (
            uint256[] memory pathElements,
            uint256[] memory pathIndices,
            uint256[] memory debugInfo
        )
    {
        require(_leafIndex < nextIndex, "Leaf index out of bounds");
        require(nextIndex > 0, "No deposits in tree");

        pathElements = new uint256[](TREE_DEPTH);
        pathIndices = new uint256[](TREE_DEPTH);
        debugInfo = new uint256[](TREE_DEPTH * 3); // [currentIndex, siblingIndex, isRightChild] for each level

        uint32 currentIndex = _leafIndex;

        for (uint32 level = 0; level < TREE_DEPTH; level++) {
            bool isRightChild = currentIndex % 2 == 1;
            pathIndices[level] = isRightChild ? 1 : 0;

            // Store debug info
            debugInfo[level * 3] = currentIndex;
            debugInfo[level * 3 + 2] = isRightChild ? 1 : 0;

            if (level == 0) {
                // Leaf level
                uint32 siblingIndex = isRightChild
                    ? currentIndex - 1
                    : currentIndex + 1;
                debugInfo[level * 3 + 1] = siblingIndex;

                if (siblingIndex < nextIndex) {
                    pathElements[level] = leaves[siblingIndex];
                } else {
                    pathElements[level] = zeros[0];
                }
            } else {
                // Internal levels
                if (isRightChild) {
                    debugInfo[level * 3 + 1] = 999999; // Marker for filledSubtrees
                    pathElements[level] = filledSubtrees[level - 1];
                } else {
                    uint32 siblingIndex = currentIndex + 1;
                    uint32 siblingLeafStart = siblingIndex << (level - 1);
                    debugInfo[level * 3 + 1] = siblingLeafStart;

                    if (siblingLeafStart < nextIndex) {
                        pathElements[level] = filledSubtrees[level - 1];
                    } else {
                        pathElements[level] = zeros[level];
                    }
                }
            }

            currentIndex /= 2;
        }

        return (pathElements, pathIndices, debugInfo);
    }

    function getLeafIndex(bytes32 _commitment) external view returns (uint32) {
        return commitmentIndex[uint256(_commitment)];
    }

    function getPathElements(
        uint32 _leafIndex
    )
        external
        view
        returns (uint256[] memory pathElements, uint256[] memory pathIndices)
    {
        require(_leafIndex < nextIndex, "Leaf index out of bounds");
        require(nextIndex > 0, "No deposits in tree");

        pathElements = new uint256[](TREE_DEPTH);
        pathIndices = new uint256[](TREE_DEPTH);

        uint32 currentIndex = _leafIndex;

        for (uint32 level = 0; level < TREE_DEPTH; level++) {
            bool isRightChild = currentIndex % 2 == 1;
            pathIndices[level] = isRightChild ? 1 : 0;

            if (level == 0) {
                // Leaf level
                uint32 siblingIndex = isRightChild
                    ? currentIndex - 1
                    : currentIndex + 1;
                if (siblingIndex < nextIndex) {
                    pathElements[level] = leaves[siblingIndex];
                } else {
                    pathElements[level] = zeros[0];
                }
            } else {
                // Use same safe approach as other functions
                if (isRightChild) {
                    pathElements[level] = filledSubtrees[level - 1];
                } else {
                    pathElements[level] = zeros[level];
                }
            }

            currentIndex /= 2;
        }

        return (pathElements, pathIndices);
    }

    function emergencyWithdraw() external onlyGovernance {
        require(isEmergencyMode, "Not in emergency mode");
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "No tokens to withdraw");
        require(
            token.transfer(governance, tokenBalance),
            "Emergency token transfer failed"
        );
    }
}
