const fs = require('fs');
const path = require('path');

const outDir = path.join(__dirname, '../out');
const abisDir = path.join(__dirname, '../abis');

// Ensure abis directory exists
if (!fs.existsSync(abisDir)) {
  fs.mkdirSync(abisDir, { recursive: true });
}

// Copy ABIs from out/ to abis/
function copyAbis() {
  if (!fs.existsSync(outDir)) {
    console.log('❌ /out directory not found. Run "forge build" first.');
    process.exit(1);
  }

  const contracts = fs.readdirSync(outDir);
  let copiedCount = 0;

  contracts.forEach(contract => {
    if (contract.endsWith('.sol')) {
      const contractDir = path.join(outDir, contract);

      if (fs.statSync(contractDir).isDirectory()) {
        const contractFiles = fs.readdirSync(contractDir);

        contractFiles.forEach(file => {
          if (file.endsWith('.json')) {
            try {
              const sourcePath = path.join(contractDir, file);
              const destPath = path.join(abisDir, file);

                            const contractData = JSON.parse(fs.readFileSync(sourcePath, 'utf8'));

              // Extract only ABI (minified)
              const abiData = {
                abi: contractData.abi || []
              };

              fs.writeFileSync(destPath, JSON.stringify(abiData));
              copiedCount++;
              console.log(`✅ Copied ${file}`);
            } catch (error) {
              console.log(`⚠️  Failed to copy ${file}:`, error.message);
            }
          }
        });
      }
    }
  });

  console.log(`\n🎉 Successfully copied ${copiedCount} contract ABIs to /abis directory`);
}

copyAbis();
