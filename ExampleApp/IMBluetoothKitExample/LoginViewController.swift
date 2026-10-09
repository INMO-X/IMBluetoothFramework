//
//  LoginViewController.swift
//  IMBluetoothKitExample
//
//  bindUser + reconnectLast demo.
//

import UIKit
import IMBluetoothKit

final class LoginViewController: UIViewController {

    private let service: BluetoothServiceProtocol = BluetoothService.shared

    private let userIDField: UITextField = {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.placeholder = "userID"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.text = "demo-user"
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private let bindButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("bindUser + reconnectLast", for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Login"
        view.backgroundColor = .systemBackground

        view.addSubview(userIDField)
        view.addSubview(bindButton)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            userIDField.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            userIDField.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            userIDField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),

            bindButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            bindButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            bindButton.topAnchor.constraint(equalTo: userIDField.bottomAnchor, constant: 16),

            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: bindButton.bottomAnchor, constant: 16),
        ])

        bindButton.addTarget(self, action: #selector(bindTapped), for: .touchUpInside)
    }

    @objc private func bindTapped() {
        let raw = (userIDField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            statusLabel.text = "Enter a non-empty userID."
            return
        }

        service.bindUser(raw)
        let scheduled = service.reconnectLast()
        statusLabel.text = scheduled
            ? "Bound \"\(raw)\"; reconnectLast() scheduled."
            : "Bound \"\(raw)\"; no last device — open device list / scan."

        let list = DeviceListViewController(service: service)
        navigationController?.pushViewController(list, animated: true)
    }
}
