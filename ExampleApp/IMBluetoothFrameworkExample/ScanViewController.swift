//
//  ScanViewController.swift
//  IMBluetoothFrameworkExample
//
//  startScan(for: C100Factory()) + connect(firstConnect: true).
//

import UIKit
import RxSwift
import IMBluetoothFramework

final class ScanViewController: UIViewController {

    private let service: BluetoothServiceProtocol
    private let bag = DisposeBag()
    private var peripherals: [BluetoothPeripheral] = []

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        return table
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
        title = "Scan C100"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Stop",
            style: .plain,
            target: self,
            action: #selector(stopTapped)
        )

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        service.startScan(for: C100Factory())
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] list in
                self?.peripherals = list
                self?.tableView.reloadData()
            })
            .disposed(by: bag)
    }

    deinit {
        service.stopScan()
    }

    @objc private func stopTapped() {
        service.stopScan()
    }
}

extension ScanViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        peripherals.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let peripheral = peripherals[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = peripheral.name
        content.secondaryText = "\(peripheral.identifier.uuidString)  RSSI \(peripheral.rssi)"
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let peripheral = peripherals[indexPath.row]
        service.stopScan()
        service.connect(peripheral: peripheral, firstConnect: true)
        navigationController?.popViewController(animated: true)
    }
}
