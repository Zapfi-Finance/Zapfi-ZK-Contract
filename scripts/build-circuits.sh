#!/bin/bash
# build-circuits.sh - Compile ZK circuits and generate verifiers

set -e


# Usage: ./build-circuits.sh [chain_name]
CHAIN_NAME=${1:-eth}

echo "🔨 Building ZapFi ZK Circuits for chain: $CHAIN_NAME"
echo "================================"

# Check if circom is installed
if ! command -v circom &> /dev/null; then
    echo "❌ circom not found. Please install: npm install -g circom"
    exit 1
fi

# Check if snarkjs is available
if ! command -v npx &> /dev/null; then
    echo "❌ npx not found. Please install Node.js"
    exit 1
fi


# Create build directory if it doesn't exist
mkdir -p build


echo "📦 Compiling transfer circuit..."
cd circuits
circom transfer.circom --r1cs --wasm --sym -l ../node_modules

echo "📦 Moving transfer artifacts to build directory..."
mv transfer.r1cs ../build/${CHAIN_NAME}_transfer.r1cs
mv transfer.sym ../build/${CHAIN_NAME}_transfer.sym
mv transfer_js/ ../build/${CHAIN_NAME}_transfer_js/

echo "📦 Compiling compliance circuit..."
circom compliance.circom --r1cs --wasm --sym -l ../node_modules

echo "📦 Moving compliance artifacts to build directory..."
mv compliance.r1cs ../build/${CHAIN_NAME}_compliance.r1cs
mv compliance.sym ../build/${CHAIN_NAME}_compliance.sym
mv compliance_js/ ../build/${CHAIN_NAME}_compliance_js/
cd ..

echo "🔑 Checking for powers of tau file..."
if [ ! -f "build/${CHAIN_NAME}_pot14_final.ptau" ]; then
    echo "⬇️  Downloading powers of tau ceremony file..."
    cd build
    
    echo "📥 Trying multiple sources for Powers of Tau 14..."
    
    # Method 1: Generate using snarkjs (most reliable for development)
    echo "🔄 Method 1: Generating using snarkjs..."

    if npx snarkjs powersoftau new bn128 14 ${CHAIN_NAME}_pot14_0000.ptau -v 2>/dev/null; then
        if npx snarkjs powersoftau contribute ${CHAIN_NAME}_pot14_0000.ptau ${CHAIN_NAME}_pot14_0001.ptau --name="Build contribution" -v -e="$(openssl rand -hex 32)" 2>/dev/null; then
            if npx snarkjs powersoftau prepare phase2 ${CHAIN_NAME}_pot14_0001.ptau ${CHAIN_NAME}_pot14_final.ptau -v 2>/dev/null; then
                echo "✅ Successfully generated Powers of Tau using snarkjs"
                rm -f ${CHAIN_NAME}_pot14_0000.ptau ${CHAIN_NAME}_pot14_0001.ptau
                FILE_SIZE=$(stat -f%z ${CHAIN_NAME}_pot14_final.ptau 2>/dev/null || stat -c%s ${CHAIN_NAME}_pot14_final.ptau 2>/dev/null || echo "0")
                echo "📊 Generated file size: $FILE_SIZE bytes"
            else
                echo "⚠️  Phase 2 preparation failed, trying downloads..."
                rm -f ${CHAIN_NAME}_pot14_0000.ptau ${CHAIN_NAME}_pot14_0001.ptau
            fi
        else
            echo "⚠️  Contribution failed, trying downloads..."
            rm -f ${CHAIN_NAME}_pot14_0000.ptau
        fi
    else
        echo "⚠️  Generation failed, trying downloads..."
    fi
    
    # Method 2: Try downloading if generation failed
    if [ ! -f "${CHAIN_NAME}_pot14_final.ptau" ]; then
        echo "🔄 Method 2: Trying download sources..."
        
        SOURCES=(
            "https://hermezptau.blob.core.windows.net/ptau/powersOfTau28_hez_final_14.ptau"
            "https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_14.ptau"
        )
        
        DOWNLOADED=false

        for url in "${SOURCES[@]}"; do
            echo "� Trying: $url"
            if curl -L --progress-bar --connect-timeout 10 --max-time 300 \
               --retry 2 --retry-delay 1 \
               -o ${CHAIN_NAME}_pot14_final.ptau "$url"; then
                # Check if we got actual binary data
                if file ${CHAIN_NAME}_pot14_final.ptau 2>/dev/null | grep -q "data\|binary"; then
                    FILE_SIZE=$(stat -f%z ${CHAIN_NAME}_pot14_final.ptau 2>/dev/null || stat -c%s ${CHAIN_NAME}_pot14_final.ptau 2>/dev/null || echo "0")
                    if [ "$FILE_SIZE" -gt 10000000 ]; then  # At least 10MB
                        echo "✅ Successfully downloaded from: $url"
                        echo "📊 File size: $FILE_SIZE bytes"
                        DOWNLOADED=true
                        break
                    else
                        echo "⚠️  File too small ($FILE_SIZE bytes), trying next source..."
                    fi
                else
                    echo "⚠️  Downloaded error page, trying next source..."
                fi
                rm -f ${CHAIN_NAME}_pot14_final.ptau
            else
                echo "❌ Download failed from: $url"
            fi
        done
        
    if [ "$DOWNLOADED" = false ]; then
            echo ""
            echo "❌ All download methods failed!"
            echo "💡 Please run our specialized download script:"
            echo "   ./scripts/download-powers-of-tau.sh"
            echo "   Then re-run this build script"
            exit 1
        fi
    fi
    

    cd ..
else
    echo "✅ Powers of Tau file already exists"
fi


echo "🛠️  Setting up trusted setup for transfer circuit..."

cd build
npx snarkjs groth16 setup ${CHAIN_NAME}_transfer.r1cs ${CHAIN_NAME}_pot14_final.ptau ${CHAIN_NAME}_transfer_0000.zkey

echo "🎲 Contributing randomness to transfer circuit..."
npx snarkjs zkey contribute ${CHAIN_NAME}_transfer_0000.zkey ${CHAIN_NAME}_transfer_0001.zkey --name="Build Script Contribution" -v -e="$(date +%s)"

echo "🔐 Exporting transfer verification key..."
npx snarkjs zkey export verificationkey ${CHAIN_NAME}_transfer_0001.zkey ${CHAIN_NAME}_transfer_verification_key.json

echo "📄 Generating Transfer Solidity verifier..."
npx snarkjs zkey export solidityverifier ${CHAIN_NAME}_transfer_0001.zkey ../contracts/${CHAIN_NAME}_TransferVerifier.sol

echo "🛠️  Setting up trusted setup for compliance circuit..."
npx snarkjs groth16 setup ${CHAIN_NAME}_compliance.r1cs ${CHAIN_NAME}_pot14_final.ptau ${CHAIN_NAME}_compliance_0000.zkey

echo "🎲 Contributing randomness to compliance circuit..."
npx snarkjs zkey contribute ${CHAIN_NAME}_compliance_0000.zkey ${CHAIN_NAME}_compliance_0001.zkey --name="Compliance Build Contribution" -v -e="$(date +%s)"

echo "🔐 Exporting compliance verification key..."
npx snarkjs zkey export verificationkey ${CHAIN_NAME}_compliance_0001.zkey ${CHAIN_NAME}_compliance_verification_key.json

echo "📄 Generating Compliance Solidity verifier..."
npx snarkjs zkey export solidityverifier ${CHAIN_NAME}_compliance_0001.zkey ../contracts/${CHAIN_NAME}_ComplianceVerifier.sol

cd ..

echo ""

echo "✅ Build Complete!"
echo "=================="
echo "📁 Artifacts location: build/"
echo "📄 Transfer verifier contract: contracts/${CHAIN_NAME}_TransferVerifier.sol"
echo "📄 Compliance verifier contract: contracts/${CHAIN_NAME}_ComplianceVerifier.sol"
echo "🔑 Transfer verification key: build/${CHAIN_NAME}_transfer_verification_key.json"
echo "🔑 Compliance verification key: build/${CHAIN_NAME}_compliance_verification_key.json"
echo ""
echo "Next steps:"
echo "1. Deploy ${CHAIN_NAME}_TransferVerifier.sol and ${CHAIN_NAME}_ComplianceVerifier.sol"
echo "2. Deploy TornadoStyleShieldedPool.sol (or ERC20 version) with both verifier addresses"
echo "3. Test both transfer and compliance functionality"
echo "4. Run integration examples"
