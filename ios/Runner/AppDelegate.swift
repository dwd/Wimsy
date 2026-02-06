import Flutter
import UIKit
import dnssd

private final class SrvQueryContext {
  var records = [[String: Any]]()
  var finished = false
  let semaphore = DispatchSemaphore(value: 0)
}

private func parseSrvRecord(rdata: UnsafeRawPointer, length: Int) -> [String: Any]? {
  if length < 7 {
    return nil
  }
  let bytes = rdata.bindMemory(to: UInt8.self, capacity: length)
  let priority = Int(bytes[0]) << 8 | Int(bytes[1])
  let weight = Int(bytes[2]) << 8 | Int(bytes[3])
  let port = Int(bytes[4]) << 8 | Int(bytes[5])
  var offset = 6
  var labels = [String]()
  while offset < length {
    let labelLength = Int(bytes[offset])
    if labelLength == 0 {
      break
    }
    let start = offset + 1
    let end = start + labelLength
    if end > length {
      break
    }
    let labelBytes = Array(UnsafeBufferPointer(start: bytes + start, count: labelLength))
    labels.append(String(bytes: labelBytes, encoding: .utf8) ?? "")
    offset = end
  }
  let host = labels.joined(separator: ".")
  if host.isEmpty {
    return nil
  }
  return [
    "host": host,
    "port": port,
    "priority": priority,
    "weight": weight
  ]
}

private func srvQueryCallback(
  _ serviceRef: DNSServiceRef?,
  _ flags: DNSServiceFlags,
  _ interfaceIndex: UInt32,
  _ errorCode: DNSServiceErrorType,
  _ fullname: UnsafePointer<Int8>?,
  _ rrtype: UInt16,
  _ rrclass: UInt16,
  _ rdlen: UInt16,
  _ rdata: UnsafeRawPointer?,
  _ ttl: UInt32,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else {
    return
  }
  let state = Unmanaged<SrvQueryContext>.fromOpaque(context).takeUnretainedValue()
  if errorCode == kDNSServiceErr_NoError && rrtype == kDNSServiceType_SRV,
     let data = rdata {
    if let record = parseSrvRecord(rdata: data, length: Int(rdlen)) {
      state.records.append(record)
    }
  }
  if flags & kDNSServiceFlagsMoreComing == 0 {
    state.finished = true
  }
  state.semaphore.signal()
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "wimsy/dns"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "resolveSrv" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let args = call.arguments as? [String: Any],
              let name = args["name"] as? String,
              !name.isEmpty else {
          result([])
          return
        }
        self?.resolveSrv(name: name, result: result)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func resolveSrv(name: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .utility).async {
      var serviceRef: DNSServiceRef?
      let context = SrvQueryContext()
      let contextPtr = Unmanaged.passRetained(context).toOpaque()
      defer {
        Unmanaged<SrvQueryContext>.fromOpaque(contextPtr).release()
      }

      let error = DNSServiceQueryRecord(&serviceRef, 0, 0, name, UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN), srvQueryCallback, contextPtr)
      if error == kDNSServiceErr_NoError, let ref = serviceRef {
        let timeout = DispatchTime.now() + .seconds(3)
        while !context.finished {
          DNSServiceProcessResult(ref)
          _ = context.semaphore.wait(timeout: timeout)
          if DispatchTime.now() >= timeout {
            break
          }
        }
        DNSServiceRefDeallocate(ref)
      }

      DispatchQueue.main.async {
        result(context.records)
      }
    }
  }

}
