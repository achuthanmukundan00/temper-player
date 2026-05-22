import CryptoKit
import Foundation

extension String {
  var pathHash: String {
    let data = Data(self.utf8)
    let hash = SHA256.hash(data: data)
    return hash.compactMap { String(format: "%02x", $0) }.joined()
  }
}
