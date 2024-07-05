
// Parse all files from the bulid/contracts folder to json and remove all properties except the abi one. Save to the same filename.
const fs = require('fs');
const path = require('path');

console.log('Start cleanning contracts...');
const buildPath = path.join(__dirname, './build/contracts');
const files = fs.readdirSync(buildPath);
files.forEach(file => {
  const filePath = path.join(buildPath, file);
  const contract
    = JSON.parse(fs.readFileSync(filePath
      , { encoding: 'utf8' }));
  const abi = contract.abi;
  const bytecode = contract.bytecode;
  const contractName = contract.contractName;
  fs.writeFileSync
    (filePath, JSON.stringify({ contractName, abi, bytecode }));
}
);
console.log('Finished cleanning contracts!');

