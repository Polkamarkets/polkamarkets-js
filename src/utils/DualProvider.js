/**
 * DualProvider - Routes requests to appropriate provider based on method type
 * Read operations use HttpProvider, write operations use window.ethereum
 */
class DualProvider {
  constructor(readProvider, writeProvider) {
    this.readProvider = readProvider;
    this.writeProvider = writeProvider;

    // Methods that require user interaction/signing (write operations)
    this.writeMethods = new Set([
      "eth_sendTransaction",
      "eth_sendRawTransaction",
      "eth_sign",
      "eth_signTransaction",
      "personal_sign",
      "eth_signTypedData",
      "eth_signTypedData_v3",
      "eth_signTypedData_v4",
      "wallet_switchEthereumChain",
      "wallet_addEthereumChain",
      "eth_accounts",
      "eth_requestAccounts",
    ]);
  }

  send(payload, callback) {
    const provider = this.writeMethods.has(payload.method)
      ? this.writeProvider
      : this.readProvider;

    return provider.send(payload, callback);
  }

  sendAsync(payload, callback) {
    const provider = this.writeMethods.has(payload.method)
      ? this.writeProvider
      : this.readProvider;

    return provider.sendAsync(payload, callback);
  }

  // Support for modern request/send pattern
  request(args) {
    const provider = this.writeMethods.has(args.method)
      ? this.writeProvider
      : this.readProvider;

    if (provider.request) {
      return provider.request(args);
    }

    // Fallback for providers that don't support request()
    return new Promise((resolve, reject) => {
      const callback = (error, response) => {
        if (error) {
          reject(error);
        } else {
          resolve(response.result);
        }
      };

      if (provider.sendAsync) {
        provider.sendAsync(
          { jsonrpc: "2.0", id: Date.now(), ...args },
          callback
        );
      } else if (provider.send) {
        provider.send({ jsonrpc: "2.0", id: Date.now(), ...args }, callback);
      } else {
        reject(
          new Error("Provider does not support request, send, or sendAsync")
        );
      }
    });
  }
}

module.exports = DualProvider;
