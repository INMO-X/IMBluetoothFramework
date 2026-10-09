#
# IMBluetoothFrameworkBinary.podspec
# ------------------------------------------------------------------
# 二进制交付版本：每个子规格对应一份预打包的 IMBluetoothFramework.xcframework
# （Full / Base / 单设备组合包），Swift module 统一为 IMBluetoothFramework。
#
# 用法：
#   ① 在内部仓库跑 Scripts/build_xcframeworks.sh 生成 XCFrameworks/
#   ② 把 XCFrameworks/、本 podspec、LICENSE 打包发给客户
#   ③ 客户 Podfile 指向本地路径，例如：
#        pod 'IMBluetoothFramework', :path => './Vendor/IMBluetoothFramework'
#        pod 'IMBluetoothFramework/Devices/C100', :path => './Vendor/IMBluetoothFramework'
#

Pod::Spec.new do |s|
  s.name             = 'IMBluetoothFramework'
  s.version          = '0.1.3'
  s.summary          = 'INMO X Bluetooth Framework (binary distribution)'
  s.description      = <<-DESC
  INMO X 蓝牙框架二进制发行版。按子规格选择 Full / Base / 单设备组合包；
  Swift module 统一为 IMBluetoothFramework。
                       DESC
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'jiangqi' => 'jiangqi@inmolens.com' }
  s.homepage         = 'https://github.com/INMO-X/IMBluetoothFramework'
  s.source           = { :git => 'https://github.com/INMO-X/IMBluetoothFramework.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.0'
  s.default_subspecs = ['Full']

  # Also ship PrivacyInfo as a CocoaPods resource bundle so it appears under Pods
  # after `pod install` (in addition to the copy embedded inside each XCFramework).
  s.resource_bundles = {
    'IMBluetoothFramework_PrivacyInfo' => ['PrivacyInfo.xcprivacy']
  }

  s.subspec 'Full' do |ss|
    ss.vendored_frameworks = 'XCFrameworks/IMBluetoothFramework.xcframework'
    ss.frameworks = 'CoreBluetooth', 'AVFoundation', 'NetworkExtension', 'Network'
    ss.dependency 'RxSwift', '~> 6.9.0'
    ss.dependency 'RxRelay', '~> 6.9.0'
    ss.dependency 'SSZipArchive', '~> 2.4'
  end

  s.subspec 'Base' do |ss|
    ss.vendored_frameworks = 'XCFrameworks/variants/Base/IMBluetoothFramework.xcframework'
    ss.frameworks = 'CoreBluetooth', 'AVFoundation'
    ss.dependency 'RxSwift', '~> 6.9.0'
    ss.dependency 'RxRelay', '~> 6.9.0'
  end

  # Devices parent has no vendored_frameworks of its own. CocoaPods still nests
  # C100/C110/XA01 under it, so `pod '…/Devices'` pulls ALL three XCFrameworks
  # (same Swift module → duplicate symbols). Customers must use Full OR exactly
  # one Devices/<X> — never the Devices parent alone, never two Devices/* lines.
  # Nested path Devices/C100 is kept for Podfile compatibility; see README.
  s.subspec 'Devices' do |ds|
    ds.subspec 'C100' do |ss|
      ss.vendored_frameworks = 'XCFrameworks/variants/C100/IMBluetoothFramework.xcframework'
      ss.frameworks = 'CoreBluetooth', 'AVFoundation', 'NetworkExtension', 'Network'
      ss.dependency 'RxSwift', '~> 6.9.0'
      ss.dependency 'RxRelay', '~> 6.9.0'
      ss.dependency 'SSZipArchive', '~> 2.4'
    end
    ds.subspec 'C110' do |ss|
      ss.vendored_frameworks = 'XCFrameworks/variants/C110/IMBluetoothFramework.xcframework'
      ss.frameworks = 'CoreBluetooth', 'AVFoundation', 'NetworkExtension'
      ss.dependency 'RxSwift', '~> 6.9.0'
      ss.dependency 'RxRelay', '~> 6.9.0'
    end
    ds.subspec 'XA01' do |ss|
      ss.vendored_frameworks = 'XCFrameworks/variants/XA01/IMBluetoothFramework.xcframework'
      ss.frameworks = 'CoreBluetooth', 'AVFoundation'
      ss.dependency 'RxSwift', '~> 6.9.0'
      ss.dependency 'RxRelay', '~> 6.9.0'
    end
  end
end
