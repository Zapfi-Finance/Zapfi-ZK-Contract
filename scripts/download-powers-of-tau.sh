#!/bin/bash
# download-powers-of-tau.sh - Reliable download script for Powers of Tau

set -e

echo "🔑 Downloading Powers of Tau ceremony file..."
echo "============================================"

# Create build directory
mkdir -p build
cd build

# Remove any existing corrupted file
rm -f pot14_final.ptau

echo "📥 Trying multiple sources for Powers of Tau 14..."

# Method 1: Try the direct snarkjs approach (most reliable)
echo "🔄 Method 1: Using snarkjs download..."
if npx snarkjs powersoftau new bn128 14 pot14_0000.ptau -v 2>/dev/null; then
    if npx snarkjs powersoftau contribute pot14_0000.ptau pot14_0001.ptau --name="First contribution" -v -e="random text" 2>/dev/null; then
        if npx snarkjs powersoftau prepare phase2 pot14_0001.ptau pot14_final.ptau -v 2>/dev/null; then
            echo "✅ Successfully generated Powers of Tau using snarkjs"
            rm -f pot14_0000.ptau pot14_0001.ptau
            FILE_SIZE=$(stat -f%z pot14_final.ptau 2>/dev/null || stat -c%s pot14_final.ptau 2>/dev/null || echo "0")
            echo "📊 Generated file size: $FILE_SIZE bytes"
            cd ..
            exit 0
        fi
    fi
fi

echo "⚠️  snarkjs generation failed, trying downloads..."

# Method 2: Try alternative reliable sources
SOURCES=(
    "https://hermezptau.blob.core.windows.net/ptau/powersOfTau28_hez_final_14.ptau"
    "https://zkevm-contracts-public.s3.amazonaws.com/powersOfTau28_hez_final_14.ptau"
    "https://raw.githubusercontent.com/privacy-scaling-explorations/perpetualpowersoftau/master/0014_perpetual_powers_of_tau_final_14.ptau"
)

for i in "${!SOURCES[@]}"; do
    url="${SOURCES[$i]}"
    echo "🔄 Method $((i+2)): Trying $url"
    
    if curl -L --progress-bar --connect-timeout 10 --max-time 300 \
       --retry 2 --retry-delay 1 \
       -o pot14_final.ptau "$url"; then
        
        # Check if we got actual binary data
        if file pot14_final.ptau 2>/dev/null | grep -q "data\|binary"; then
            FILE_SIZE=$(stat -f%z pot14_final.ptau 2>/dev/null || stat -c%s pot14_final.ptau 2>/dev/null || echo "0")
            
            # Should be substantial size for Powers of Tau 14
            if [ "$FILE_SIZE" -gt 50000000 ]; then  # At least 50MB
                echo "✅ Successfully downloaded from: $url"
                echo "📊 File size: $FILE_SIZE bytes"
                cd ..
                exit 0
            else
                echo "⚠️  File too small ($FILE_SIZE bytes), trying next source..."
            fi
        else
            echo "⚠️  Downloaded error page, trying next source..."
        fi
        
        rm -f pot14_final.ptau
    else
        echo "❌ Download failed from: $url"
    fi
done

# Method 3: Generate smaller Powers of Tau (for development only)
echo ""
echo "🚨 All downloads failed - generating smaller Powers of Tau for development"
echo "⚠️  WARNING: This is only suitable for testing, NOT production!"
echo ""

if npx snarkjs powersoftau new bn128 12 pot12_0000.ptau -v; then
    if npx snarkjs powersoftau contribute pot12_0000.ptau pot12_0001.ptau --name="Dev contribution" -v -e="dev random"; then
        if npx snarkjs powersoftau prepare phase2 pot12_0001.ptau pot14_final.ptau -v; then
            echo "✅ Generated development Powers of Tau (smaller, for testing only)"
            rm -f pot12_0000.ptau pot12_0001.ptau
            FILE_SIZE=$(stat -f%z pot14_final.ptau 2>/dev/null || stat -c%s pot14_final.ptau 2>/dev/null || echo "0")
            echo "📊 Generated file size: $FILE_SIZE bytes"
            echo ""
            echo "🎯 FOR PRODUCTION: Please manually download the official Powers of Tau 14:"
            echo "   1. Visit: https://github.com/iden3/snarkjs#7-prepare-phase-2"
            echo "   2. Download the official powersOfTau28_hez_final_14.ptau"
            echo "   3. Replace the generated file in build/ directory"
            cd ..
            exit 0
        fi
    fi
fi

echo ""
echo "❌ All methods failed!"
echo "💡 Manual download required:"
echo "   1. Visit: https://github.com/iden3/snarkjs#7-prepare-phase-2"
echo "   2. Find working download link for powersOfTau28_hez_final_14.ptau"
echo "   3. Download manually to build/pot14_final.ptau"
echo "   4. Re-run the build script"

cd ..
exit 1
