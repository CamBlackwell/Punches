import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    
    private let appGroupIdentifier = SharedConstants.appGroupIdentifier
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        preferredContentSize = CGSize(width: 100, height: 160)
        
        view.backgroundColor = .systemBackground
        
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 20
        stackView.alignment = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        let titleLabel = UILabel()
        titleLabel.text = "Import to Punches"
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textAlignment = .center
        
        let addButton = UIButton(type: .system)
        var addConfig = UIButton.Configuration.filled()
        addConfig.title = "Add to Library"
        addConfig.baseBackgroundColor = .systemBlue
        addConfig.baseForegroundColor = .white
        addConfig.cornerStyle = .medium
        addConfig.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 32, bottom: 16, trailing: 32)
        addButton.configuration = addConfig
        addButton.addTarget(self, action: #selector(addToLibrary), for: .touchUpInside)
        
        let addAndPlayButton = UIButton(type: .system)
        var addAndPlayConfig = UIButton.Configuration.filled()
        addAndPlayConfig.title = "Add and Play"
        addAndPlayConfig.baseBackgroundColor = .systemGreen
        addAndPlayConfig.baseForegroundColor = .white
        addAndPlayConfig.cornerStyle = .medium
        addAndPlayConfig.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 32, bottom: 16, trailing: 32)
        addAndPlayButton.configuration = addAndPlayConfig
        addAndPlayButton.addTarget(self, action: #selector(addAndPlay), for: .touchUpInside)
        
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(addButton)
        stackView.addArrangedSubview(addAndPlayButton)
        stackView.addArrangedSubview(cancelButton)
        
        view.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
            addButton.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            addAndPlayButton.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
    }
    
    @objc private func addToLibrary() {
        processFiles(shouldOpenApp: false)
    }
    
    @objc private func addAndPlay() {
        processFiles(shouldOpenApp: true)
    }
    
    @objc private func cancel() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
    
    private func processFiles(shouldOpenApp: Bool) {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            cancel()
            return
        }
        
        var fileURLs: [URL] = []
        let group = DispatchGroup()
        
        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                    group.enter()
                    
                    provider.loadItem(forTypeIdentifier: UTType.audio.identifier, options: nil) { (item, error) in
                        defer { group.leave() }
                        
                        if let error = error {
                            print("Error loading item: \(error)")
                            return
                        }
                        
                        if let url = item as? URL {
                            fileURLs.append(url)
                        }
                    }
                }
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            if fileURLs.isEmpty {
                self.cancel()
                return
            }
            
            self.saveFilesToSharedContainer(fileURLs)
            
            if shouldOpenApp {
                self.openMainApp()
            } else {
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
    
    private func saveFilesToSharedContainer(_ urls: [URL]) {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            print("Could not access app group container")
            return
        }
        
        let sharedDirectory = groupURL.appendingPathComponent("PendingImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        
        var savedURLs: [String] = []
        
        for url in urls {
            let fileName = url.lastPathComponent
            let destinationURL = sharedDirectory.appendingPathComponent(fileName)
            
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                
                try FileManager.default.copyItem(at: url, to: destinationURL)
                savedURLs.append(fileName)
                print("Saved file: \(fileName)")
            } catch {
                print("Error saving file \(fileName): \(error)")
            }
        }
        
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            let existing = groupDefaults.stringArray(forKey: SharedConstants.pendingFilesKey) ?? []
            groupDefaults.set(existing + savedURLs, forKey: SharedConstants.pendingFilesKey)
            groupDefaults.synchronize()
        }
    }
    
    private func openMainApp() {
        guard let url = URL(string: SharedConstants.openAndPlayScheme) else { return }
        
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:]) { [weak self] _ in
                    self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                }
                return
            }
            responder = responder?.next
        }
        
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
