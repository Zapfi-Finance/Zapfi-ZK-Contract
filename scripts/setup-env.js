#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

async function setupEnvironment() {
  console.log('🔧 Setting up Hardhat environment variables...\n');
  
  const envPath = path.join(__dirname, '..', '.env');
  
  // Check if .env already exists
  if (fs.existsSync(envPath)) {
    const answer = await question('⚠️  .env file already exists. Overwrite? (y/N): ');
    if (answer.toLowerCase() !== 'y') {
      console.log('Setup cancelled.');
      process.exit(0);
    }
  }

  console.log('Please provide the following information:\n');

  const config = {};

  // Private key
  config.PRIVATE_KEY = await question('🔑 Your wallet private key (without 0x): ');
  
  // RPC URLs
  console.log('\n📡 RPC URLs (you can get these from Alchemy, Infura, etc.):');
  config.SEPOLIA_URL = await question('Sepolia testnet URL: ');
  config.MAINNET_URL = await question('Ethereum mainnet URL (optional): ');
  
  // API keys
  console.log('\n🔍 API keys for contract verification:');
  config.ETHERSCAN_API_KEY = await question('Etherscan API key: ');
  
  // Optional settings
  console.log('\n⚙️  Optional settings:');
  const reportGas = await question('Enable gas reporting? (Y/n): ');
  config.REPORT_GAS = reportGas.toLowerCase() !== 'n' ? 'true' : 'false';
  
  const relayerFee = await question('Relayer fee in basis points (default 250 = 2.5%): ');
  config.RELAYER_FEE = relayerFee || '250';

  // Create .env content
  const envContent = `# Hardhat Environment Configuration
# Generated on ${new Date().toISOString()}

# Private key for deployment (without 0x prefix)
PRIVATE_KEY=${config.PRIVATE_KEY}

# RPC URLs for different networks
SEPOLIA_URL=${config.SEPOLIA_URL}
MAINNET_URL=${config.MAINNET_URL}

# Etherscan API key for contract verification
ETHERSCAN_API_KEY=${config.ETHERSCAN_API_KEY}

# Gas reporting settings
REPORT_GAS=${config.REPORT_GAS}

# Deployment settings
RELAYER_FEE=${config.RELAYER_FEE}

# Optional: Add more networks as needed
# GOERLI_URL=
# POLYGON_URL=
# ARBITRUM_URL=
# POLYGONSCAN_API_KEY=
# COINMARKETCAP_API_KEY=
`;

  // Write .env file
  fs.writeFileSync(envPath, envContent);
  
  console.log('\n✅ Environment configuration saved to .env');
  console.log('\n📝 Next steps:');
  console.log('1. Review and edit .env file if needed');
  console.log('2. Compile contracts: npm run hardhat:compile');
  console.log('3. Deploy: npm run deploy:poseidon:sepolia');
  console.log('\n⚠️  Remember: Never commit .env file to git!');
  
  rl.close();
}

function question(prompt) {
  return new Promise((resolve) => {
    rl.question(prompt, (answer) => {
      resolve(answer.trim());
    });
  });
}

setupEnvironment().catch(console.error);
