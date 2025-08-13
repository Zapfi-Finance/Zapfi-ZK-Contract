#!/bin/bash

echo "🔧 Setting up Foundry for ZapFi ZK project..."

# Check if Foundry is installed
if ! command -v forge &> /dev/null; then
    echo "📦 Installing Foundry..."
    curl -L https://foundry.paradigm.xyz | bash
    source ~/.bashrc 2>/dev/null || source ~/.bash_profile 2>/dev/null || true
    foundryup
else
    echo "✅ Foundry is already installed"
fi

# Initialize Foundry project (this will create lib/ directory)
echo "🏗️  Initializing Foundry project..."
forge init --no-git --no-commit --force 2>/dev/null || true

# Install forge-std dependency
echo "📚 Installing forge-std dependency..."
forge install foundry-rs/forge-std --no-git --no-commit 2>/dev/null || true

# Create remappings for our contract structure
echo "📝 Creating remappings.txt..."
cat > remappings.txt << EOF
forge-std/=lib/forge-std/src/
@openzeppelin/=lib/openzeppelin-contracts/
EOF

# Clean up any conflicting files
echo "🧹 Cleaning up..."
rm -rf src/Counter.sol test/Counter.t.sol script/Counter.s.sol 2>/dev/null || true

echo "✅ Foundry setup complete!"
echo ""
echo "🚀 You can now use:"
echo "  npm run compile:contracts    # Compile with Foundry"
echo "  npm run test:foundry        # Run Foundry tests"
echo "  npm run deploy:poseidon:localhost  # Deploy locally"
echo ""
echo "📋 Next steps:"
echo "1. Make sure your .env file has PRIVATE_KEY set"
echo "2. Run: npm run compile:contracts"
echo "3. Run: npm run test:foundry"
