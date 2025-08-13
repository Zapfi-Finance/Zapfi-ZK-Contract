# ZapFi ZK Circuits

This directory contains the Zero-Knowledge circuit definitions for the ZapFi privacy-preserving transfer system.

## 📁 Circuit Files

### `transfer.circom`
**Main Transfer Circuit**
- Implements private value transfers with Merkle proofs
- Validates input commitment exists in Merkle tree
- Ensures value conservation (input = output1 + output2)
- Generates nullifier for double-spend prevention
- **Security**: Includes merkle root as public signal

**Public Signals:**
1. `nullifierHash` - Prevents double spending
2. `outCommit1` - First output commitment
3. `outCommit2` - Second output commitment  
4. `merkleRoot` - **CRITICAL**: Proves tree membership

**Private Inputs:**
- `inAmount`, `inBlinding` - Input note secrets
- `inPathElements[]`, `inPathIndices[]` - Merkle proof
- `root` - Merkle tree root
- `out1Amount`, `out1Blinding` - Output 1 secrets
- `out2Amount`, `out2Blinding` - Output 2 secrets

### `merkle.circom`
**Merkle Tree Verification Circuit**
- Verifies Merkle inclusion proofs
- Configurable tree depth
- Optimized for Poseidon hash function
- Used as component in transfer circuit

## 🔨 Compilation

### Prerequisites
```bash
# Install circom compiler
npm install -g circom

# Install circuit libraries
npm install circomlib
```

### Build Process
```bash
# Build all circuits
npm run build

```

### Output Files
- `build/*.r1cs` - R1CS constraint system
- `build/*.sym` - Symbol table for debugging
- `build/*_js/` - WebAssembly and JS bindings

## ⚙️ Circuit Parameters

### Tree Depth
Currently configured for depth 20 (supports 1M+ commitments):
```circom
component main = Transfer(20);
```

### Constraint Count
- **Total Constraints**: 12,449
- **Linear Constraints**: 6,577
- **Non-linear Constraints**: 5,872

### Performance
- **Proof Generation**: 2-5 seconds
- **Verification**: ~15ms on-chain
- **Memory Usage**: ~2GB during setup

## 🔒 Security Features

### Cryptographic Guarantees
✅ **Merkle Membership**: Proves input exists in tree
✅ **Value Conservation**: input = output1 + output2  
✅ **Nullifier Uniqueness**: Prevents double spending
✅ **Root Binding**: Links proof to specific tree state

### Attack Prevention
✅ **Fake Commitment**: Root must be proven in circuit
✅ **Value Inflation**: Constraint prevents value creation
✅ **Double Spend**: Nullifier tracking in contract
✅ **Tree Forgery**: Cryptographic Merkle proof required

## 🧪 Circuit Testing

### Input Validation
```javascript
// Valid inputs example
const circuitInputs = {
    inAmount: 1000000,
    inBlinding: randomBytes(32),
    inPathElements: merkleProof.pathElements,
    inPathIndices: merkleProof.indices,
    root: merkleTree.root,
    out1Amount: 800000,  // withdrawal
    out1Blinding: randomBytes(32),
    out2Amount: 200000,  // change
    out2Blinding: randomBytes(32)
};
```

### Constraint Verification
```bash
# Generate witness
node transfer_js/generate_witness.js transfer_js/transfer.wasm input.json witness.wtns

# Verify constraints
snarkjs wtns check transfer.r1cs witness.wtns
```

## 🔧 Development

### Modifying Circuits
1. Edit `.circom` files
2. Recompile with `circom`
3. Regenerate trusted setup
4. Update contract verifier
5. Test thoroughly

### Adding New Features
- **Additional Constraints**: Add to circuit logic
- **New Public Signals**: Update contract interface
- **Optimization**: Use efficient circom patterns
- **Security Review**: Verify all invariants hold

### Debugging
```bash
# Generate detailed symbol information
circom transfer.circom --sym -l ../node_modules

# Use circom debugging tools
node transfer_js/debug_witness.js
```

## 📊 Circuit Analysis

### Constraint Breakdown
- **Poseidon Hashing**: ~300 constraints per hash
- **Merkle Verification**: ~6000 constraints (depth 20)
- **Value Constraints**: ~100 constraints
- **Signal Routing**: ~6000 constraints

### Optimization Opportunities
- **Custom Gates**: For specific operations
- **Lookup Tables**: For repeated computations
- **Constraint Reduction**: Algebraic optimizations
- **Parallelization**: Independent constraint groups

## 🚀 Production Deployment

### Trusted Setup
```bash
# Use larger powers of tau for production
wget https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_15.ptau

# Multi-party ceremony recommended
snarkjs zkey contribute circuit.zkey circuit_final.zkey
```

### Verification
```bash
# Verify final setup
snarkjs zkey verify transfer.r1cs pot15_final.ptau circuit_final.zkey

# Export verification key
snarkjs zkey export verificationkey circuit_final.zkey vk.json
```

## 📚 Technical References

### Circom Documentation
- [Circom Language Guide](https://docs.circom.io/)
- [Constraint Writing Best Practices](https://docs.circom.io/getting-started/writing-constraints/)
- [Circuit Optimization Techniques](https://docs.circom.io/getting-started/optimization/)

### Cryptographic Background
- [Groth16 Protocol](https://eprint.iacr.org/2016/260.pdf)
- [Merkle Tree Security](https://blog.ethereum.org/2015/11/15/merkling-in-ethereum/)
- [Poseidon Hash Function](https://www.poseidon-hash.info/)

## ⚠️ Security Considerations

### Circuit Security
1. **All constraints must be satisfied**
2. **No trusted inputs without verification**
3. **Public signals must match contract expectations**
4. **Arithmetic overflow protection required**

### Implementation Security
1. **Witness data is private** during proof generation
2. **Setup ceremony must be trusted**
3. **Circuit updates require new ceremony**
4. **Constraint violations indicate bugs**

## 🔄 Version History

### v1.0.0 (Current)
- ✅ Merkle root as public signal (security fix)
- ✅ Poseidon hash function
- ✅ 20-level Merkle tree support
- ✅ Value conservation constraints
- ✅ Production-ready optimization

### Previous Versions
- v0.1.0: Initial implementation (vulnerable)
- v0.2.0: Added value conservation
- v0.3.0: Merkle tree integration
