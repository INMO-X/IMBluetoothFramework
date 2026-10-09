//
//  DeviceListViewController.swift
//  IMBluetoothKitExample
//
//  service.devices + connectionState / reconnecting badges + C100 battery.
//

import UIKit
import RxSwift
import IMBluetoothKit

final class DeviceListViewController: UIViewController {

    private let service: BluetoothServiceProtocol
    private let bag = DisposeBag()

    private var devices: [BluetoothDevice] = []
    private var reconnectingIDs: Set<UUID> = []
    private var connectionState: ConnectionState = .idle
    private var batteryByDeviceID: [String: Int?] = [:]

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        return table
    }()

    private let stateBanner: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(service: BluetoothServiceProtocol) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Devices"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Scan", style: .plain, target: self, action: #selector(scanTapped)),
            UIBarButtonItem(title: "Unbind", style: .plain, target: self, action: #selector(unbindTapped)),
        ]

        view.addSubview(stateBanner)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            stateBanner.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stateBanner.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stateBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: stateBanner.bottomAnchor, constant: 8),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        bindStreams()
    }

    private func bindStreams() {
        service.devices
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] list in
                guard let self else { return }
                self.devices = list
                self.subscribeDeviceStates(list)
                self.tableView.reloadData()
            })
            .disposed(by: bag)

        service.reconnecting
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] ids in
                self?.reconnectingIDs = ids
                self?.tableView.reloadData()
            })
            .disposed(by: bag)

        service.connectionState
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] state in
                self?.connectionState = state
                self?.stateBanner.text = "connectionState: \(Self.describe(state))"
                self?.tableView.reloadData()
            })
            .disposed(by: bag)
    }

    private var stateBags: [String: DisposeBag] = [:]

    private func subscribeDeviceStates(_ list: [BluetoothDevice]) {
        let ids = Set(list.map(\.identifier))
        for key in stateBags.keys where !ids.contains(key) {
            stateBags.removeValue(forKey: key)
            batteryByDeviceID.removeValue(forKey: key)
        }

        for device in list {
            guard stateBags[device.identifier] == nil else { continue }
            let deviceBag = DisposeBag()
            stateBags[device.identifier] = deviceBag

            device.stateStream
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] state in
                    guard let self else { return }
                    let battery = (state as? C100DeviceState)?.battery
                    self.batteryByDeviceID[device.identifier] = battery
                    self.tableView.reloadData()
                })
                .disposed(by: deviceBag)
        }
    }

    @objc private func scanTapped() {
        let scan = ScanViewController(service: service)
        navigationController?.pushViewController(scan, animated: true)
    }

    @objc private func unbindTapped() {
        service.unbindUser()
        navigationController?.popToRootViewController(animated: true)
    }

    private static func describe(_ state: ConnectionState) -> String {
        switch state {
        case .poweredOff: return "poweredOff"
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .connecting(let id, _): return "connecting \(id.uuidString.prefix(8))"
        case .connected(let id, _): return "connected \(id.uuidString.prefix(8))"
        case .disconnecting(let id, _): return "disconnecting \(id.uuidString.prefix(8))"
        case .disconnected(let id, _, let reason): return "disconnected \(id.uuidString.prefix(8)) \(reason ?? "")"
        case .failed(let id, _, let reason): return "failed \(id.uuidString.prefix(8)) \(reason)"
        }
    }

    private func badge(for device: BluetoothDevice) -> String {
        var parts: [String] = []
        if let uuid = UUID(uuidString: device.identifier), reconnectingIDs.contains(uuid) {
            parts.append("reconnecting")
        }
        switch connectionState {
        case .connecting(let id, _) where id.uuidString == device.identifier:
            parts.append("connecting")
        case .connected(let id, _) where id.uuidString == device.identifier:
            parts.append("connected")
        case .failed(let id, _, _) where id.uuidString == device.identifier:
            parts.append("failed")
        default:
            break
        }
        if let battery = batteryByDeviceID[device.identifier], let value = battery {
            parts.append("bat \(value)%")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

extension DeviceListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        devices.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let device = devices[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = device.name
        content.secondaryText = "\(device.identifier)\n\(badge(for: device))"
        cell.contentConfiguration = content
        return cell
    }
}
