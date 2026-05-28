//
//  TranslationSettingsViewController.swift
//  NetNewsWire-iOS
//

import UIKit
import Secrets

final class TranslationSettingsViewController: UITableViewController, UITextFieldDelegate {

    private let baseURLField = UITextField()
    private let apiKeyField = UITextField()
    private let modelField = UITextField()
    private let testButton = UIButton(type: .system)
    private let clearCacheButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    private var settings = TranslationSettings()

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Translation", comment: "Translation settings screen title")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsSelection = false

        baseURLField.placeholder = "https://api.deepseek.com/v1"
        baseURLField.text = settings.baseURL.absoluteString
        baseURLField.autocorrectionType = .no
        baseURLField.autocapitalizationType = .none
        baseURLField.keyboardType = .URL
        baseURLField.delegate = self

        apiKeyField.placeholder = "sk-..."
        apiKeyField.text = TranslationAPIKeyStore.load() ?? ""
        apiKeyField.isSecureTextEntry = true
        apiKeyField.autocorrectionType = .no
        apiKeyField.autocapitalizationType = .none
        apiKeyField.delegate = self

        modelField.placeholder = "deepseek-chat"
        modelField.text = settings.model
        modelField.autocorrectionType = .no
        modelField.autocapitalizationType = .none
        modelField.delegate = self

        testButton.setTitle(NSLocalizedString("Test Connection", comment: ""), for: .normal)
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)

        clearCacheButton.setTitle(NSLocalizedString("Clear Translation Cache", comment: ""), for: .normal)
        clearCacheButton.setTitleColor(.systemRed, for: .normal)
        clearCacheButton.addTarget(self, action: #selector(clearCacheTapped), for: .touchUpInside)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        save()
    }

    // MARK: - Table

    private enum Row: Int, CaseIterable {
        case baseURL = 0, apiKey, model, test, clearCache, status
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        guard let row = Row(rawValue: indexPath.row) else { return cell }

        switch row {
        case .baseURL:    return makeFieldRow(cell: cell, label: NSLocalizedString("Base URL", comment: ""), field: baseURLField)
        case .apiKey:     return makeFieldRow(cell: cell, label: NSLocalizedString("API Key", comment: ""), field: apiKeyField)
        case .model:      return makeFieldRow(cell: cell, label: NSLocalizedString("Model", comment: ""), field: modelField)
        case .test:       return makeButtonRow(cell: cell, view: testButton)
        case .clearCache: return makeButtonRow(cell: cell, view: clearCacheButton)
        case .status:     return makeButtonRow(cell: cell, view: statusLabel)
        }
    }

    private func makeFieldRow(cell: UITableViewCell, label: String, field: UITextField) -> UITableViewCell {
        let labelView = UILabel()
        labelView.text = label
        labelView.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(labelView)
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            labelView.widthAnchor.constraint(equalToConstant: 100),
            field.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        return cell
    }

    private func makeButtonRow(cell: UITableViewCell, view: UIView) -> UITableViewCell {
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12)
        ])
        return cell
    }

    // MARK: - Save

    private func save() {
        if let s = baseURLField.text, TranslationSettings.isValidBaseURLString(s), let url = URL(string: s) {
            settings.baseURL = url
        }
        settings.model = modelField.text ?? ""
        if let key = apiKeyField.text, !key.isEmpty {
            try? TranslationAPIKeyStore.save(key)
        } else {
            try? TranslationAPIKeyStore.delete()
        }
    }

    // MARK: - Actions

    @objc private func testTapped() {
        save()
        guard let key = TranslationAPIKeyStore.load(), !key.isEmpty else {
            statusLabel.text = NSLocalizedString("Enter an API key first.", comment: "")
            return
        }
        statusLabel.text = NSLocalizedString("Testing…", comment: "")
        statusLabel.textColor = .secondaryLabel
        let service = LLMTranslationService()
        let base = settings.baseURL
        let model = settings.model
        Task { @MainActor [weak self] in
            do {
                let html = try await service.translate(
                    title: "Hello",
                    bodyHTML: "<p>Test.</p>",
                    baseURL: base,
                    model: model,
                    apiKey: key
                )
                self?.statusLabel.text = NSLocalizedString("OK: ", comment: "") + String(html.prefix(80))
                self?.statusLabel.textColor = .systemGreen
            } catch let LLMTranslationService.TranslationError.providerError(msg, status) {
                self?.statusLabel.text = "HTTP \(status): \(msg)"
                self?.statusLabel.textColor = .systemRed
            } catch {
                self?.statusLabel.text = error.localizedDescription
                self?.statusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func clearCacheTapped() {
        TranslationStore(databaseURL: TranslationStore.defaultDatabaseURL()).clearAll()
        let alert = UIAlertController(
            title: NSLocalizedString("Cache Cleared", comment: ""),
            message: nil,
            preferredStyle: .alert)
        alert.addAction(.init(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }
}
