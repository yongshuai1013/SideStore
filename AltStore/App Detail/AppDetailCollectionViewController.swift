//
//  AppDetailCollectionViewController.swift
//  AltStore
//
//  Created by Riley Testut on 5/5/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import SwiftUI
import CoreData

extension AppDetailCollectionViewController
{
    private enum Section: Int
    {
        case privacy
        case knownEntitlements
        case unknownEntitlements
    }
    
    private enum ElementKind: String
    {
        case title
        case button
    }
    
    @objc(SafeAreaIgnoringCollectionView)
    private class SafeAreaIgnoringCollectionView: UICollectionView
    {
        override var safeAreaInsets: UIEdgeInsets {
            get {
                // Fixes incorrect layout if collection view height is taller than safe area height.
                return .zero
            }
            set {
                // There MUST be a setter for this to work, even if it does nothing ¯\_(ツ)_/¯
            }
        }
    }
}

class AppDetailCollectionViewController: UICollectionViewController
{
    let app: StoreApp
    private let privacyPermissions: [AppPermission]
    private let knownEntitlementPermissions: [AppPermission]
    private let unknownEntitlementPermissions: [AppPermission]
    
    private lazy var dataSource = self.makeDataSource()
    private lazy var privacyDataSource = self.makePrivacyDataSource()
    private lazy var entitlementsDataSource = self.makeEntitlementsDataSource()
    
    // iOS 15 only: UIHostingConfiguration is iOS 16+, so the legacy
    // privacy card is hosted in a UIHostingController whose view is
    // embedded in the privacy cell instead. There is only ever a
    // single privacy item, so a single hosting controller is retained
    // here and its root view is updated whenever the cell is configured.
    private var legacyPrivacyHostingController: UIHostingController<LegacyAppPermissionsCard<AppPermission>>?
    
    private var headerRegistration: UICollectionView.SupplementaryRegistration<UICollectionViewListCell>!
    
    override var collectionViewLayout: UICollectionViewCompositionalLayout {
        return self.collectionView.collectionViewLayout as! UICollectionViewCompositionalLayout
    }
    
    init?(app: StoreApp, coder: NSCoder)
    {
        self.app = app
        
        let comparator: (AppPermission, AppPermission) -> Bool = { (permissionA, permissionB) -> Bool in
            switch (permissionA.localizedName, permissionB.localizedName)
            {
            case (let nameA?, let nameB?):
                // Sort by localizedName, if both have one.
                return nameA.localizedStandardCompare(nameB) == .orderedAscending
                
            case (nil, nil):
                // Sort by raw permission value as fallback.
                return permissionA.permission.rawValue < permissionB.permission.rawValue
                
            // Sort "known" permissions before "unknown" ones.
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }
        
        self.privacyPermissions = app.permissions.filter { $0.type == .privacy }.sorted(by: comparator)
        
        let entitlementPermissions = app.permissions.lazy.filter { $0.type == .entitlement }
        self.knownEntitlementPermissions = entitlementPermissions.filter { $0.isKnown }.sorted(by: comparator)
        self.unknownEntitlementPermissions = entitlementPermissions.filter { !$0.isKnown }.sorted(by: comparator)
        
        super.init(coder: coder)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        // Allow parent background color to show through.
        self.collectionView.backgroundColor = nil
        
        // Match the parent table view margins.
        self.collectionView.directionalLayoutMargins.leading = 20
        self.collectionView.directionalLayoutMargins.trailing = 20
        
        let collectionViewLayout = self.makeLayout()
        self.collectionView.collectionViewLayout = collectionViewLayout
        
        self.collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "PrivacyCell")
        self.collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: CellContentGenericCellIdentifier)
        
        self.headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] (headerView, elementKind, indexPath) in
            var configuration = UIListContentConfiguration.plainHeader()
            
            // Match parent table view section headers.
            configuration.textProperties.font = UIFont.systemFont(ofSize: 22, weight: .bold) // .boldSystemFont(ofSize:) returns *semi-bold* color smh.
            configuration.textProperties.color = .label
            
            switch Section(rawValue: indexPath.section)!
            {
            case .privacy: break
            case .knownEntitlements:
                configuration.text = nil
                
                configuration.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .callout)
                configuration.textToSecondaryTextVerticalPadding = 8
                configuration.secondaryText = NSLocalizedString("Entitlements are additional permissions that grant access to certain system services, including potentially sensitive information.", comment: "")
                
            case .unknownEntitlements:
                configuration.text = NSLocalizedString("Other Entitlements", comment: "")
                
                let action = UIAction(image: UIImage(systemName: "questionmark.circle")) { _ in
                    self?.showUnknownEntitlementsAlert()
                }
                
                let helpButton = UIButton(primaryAction: action)
                let customAccessory = UICellAccessory.customView(configuration: .init(customView: helpButton, placement: .trailing(), tintColor: self?.app.tintColor ?? .altPrimary))
                headerView.accessories = [customAccessory]
            }
                        
            headerView.contentConfiguration = configuration
            headerView.backgroundConfiguration = UIBackgroundConfiguration.clear()
        }
        
        self.dataSource.proxy = self
        self.collectionView.dataSource = self.dataSource
        self.dataSource.contentView = self.collectionView
        self.collectionView.delegate = self
    }
}

private extension AppDetailCollectionViewController
{
    func makeLayout() -> UICollectionViewCompositionalLayout
    {
        let layoutConfig = UICollectionViewCompositionalLayoutConfiguration()
        layoutConfig.contentInsetsReference = .layoutMargins
        
        let layout = UICollectionViewCompositionalLayout(sectionProvider: { [privacyPermissions, knownEntitlementPermissions, unknownEntitlementPermissions] (sectionIndex, layoutEnvironment) -> NSCollectionLayoutSection? in
            guard let section = Section(rawValue: sectionIndex) else { return nil }
            switch section
            {
            case .privacy:
                guard !privacyPermissions.isEmpty else { return nil }
                
                let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(50)) // Underestimate height to prevent jumping size abruptly.
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                
                let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(50))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
                
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.interGroupSpacing = 10
                return layoutSection
                
            case .knownEntitlements where !knownEntitlementPermissions.isEmpty: fallthrough
            case .unknownEntitlements where !unknownEntitlementPermissions.isEmpty:
                var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.headerMode = .supplementary
                #if !os(tvOS)
                configuration.showsSeparators = false
                #endif
                configuration.backgroundColor = .altBackground
                
                let layoutSection = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: layoutEnvironment)
                layoutSection.contentInsets.top = 4
                return layoutSection
                
            case .knownEntitlements, .unknownEntitlements: return nil
            }
        }, configuration: layoutConfig)
        
        return layout
    }
    
    func makeDataSource() -> CompositeCollectionViewDataSource<AppPermission>
    {
        let dataSource = CompositeCollectionViewDataSource<AppPermission>(dataSources: [self.privacyDataSource, self.entitlementsDataSource])
        return dataSource
    }
    
    func makePrivacyDataSource() -> DynamicCollectionViewDataSource<AppPermission>
    {
        let dataSource = DynamicCollectionViewDataSource<AppPermission>()
        dataSource.cellIdentifierHandler = { _ in "PrivacyCell" }
        dataSource.numberOfSectionsHandler = { 1 }
        dataSource.dynamicCellConfigurationHandler = { [weak self] (cell, indexPath) in
            guard let self else { return }
            
            if #available(iOS 16, tvOS 16, *)
            {
                cell.contentConfiguration = UIHostingConfiguration {
                    AppPermissionsCard(title: "Privacy",
                                       description: "\(self.app.name) may request access to the following:",
                                       tintColor: Color(uiColor: self.app.tintColor ?? .altPrimary),
                                       permissions: self.privacyPermissions)
                }
                .margins(.horizontal, 0)
            }
            else
            {
                // iOS 15: UIHostingConfiguration is unavailable, so host
                // the legacy card's view in the cell directly instead.
                self.configureLegacyPrivacyCell(cell)
            }
        }
        
        dataSource.numberOfItemsHandler = { [privacyPermissions] _ in !privacyPermissions.isEmpty ? 1 : 0 }
        
        return dataSource
    }
    
    // iOS 15 fallback for makePrivacyDataSource(), following the same
    // #available split used above for UIHostingConfiguration.
    func configureLegacyPrivacyCell(_ cell: UICollectionViewCell)
    {
        let card = LegacyAppPermissionsCard(title: "Privacy",
                                            description: "\(self.app.name) may request access to the following:",
                                            tintColor: Color(uiColor: self.app.tintColor ?? .altPrimary),
                                            permissions: self.privacyPermissions)
        
        let hostingController: UIHostingController<LegacyAppPermissionsCard<AppPermission>>
        
        if let existingHostingController = self.legacyPrivacyHostingController
        {
            hostingController = existingHostingController
            hostingController.rootView = card
        }
        else
        {
            hostingController = UIHostingController(rootView: card)
            hostingController.view.backgroundColor = .clear
            
            self.addChild(hostingController)
            hostingController.didMove(toParent: self)
            
            self.legacyPrivacyHostingController = hostingController
        }
        
        hostingController.view.removeFromSuperview()
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(hostingController.view)
        
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
        ])
    }
    
    func makeEntitlementsDataSource() -> CompositeCollectionViewDataSource<AppPermission>
    {
        let knownEntitlementsDataSource = ArrayCollectionViewDataSource<AppPermission>(items: self.knownEntitlementPermissions)
        let unknownEntitlementsDataSource = ArrayCollectionViewDataSource<AppPermission>(items: self.unknownEntitlementPermissions)
        
        let dataSource = CompositeCollectionViewDataSource<AppPermission>(dataSources: [knownEntitlementsDataSource, unknownEntitlementsDataSource])
        dataSource.cellConfigurationHandler = { [weak self] (cell, appPermission, _) in
            let cell = cell as! UICollectionViewListCell
            let tintColor = self?.app.tintColor ?? .altPrimary
            
            var content = cell.defaultContentConfiguration()
            content.text = appPermission.localizedDisplayName
            content.secondaryText = appPermission.permission.rawValue
            content.secondaryTextProperties.color = .secondaryLabel
            
            if appPermission.isKnown
            {
                content.image = UIImage(systemName: appPermission.effectiveSymbolName)
                content.imageProperties.tintColor = tintColor
                
                if #available(iOS 15.4, tvOS 15.4, *)
                {
                    let detailAccessory = UICellAccessory.detail(options: .init(tintColor: tintColor)) {
                        self?.showPermissionAlert(for: appPermission)
                    }
                    cell.accessories = [detailAccessory]
                }
            }
            
            cell.contentConfiguration = content
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        }
        
        return dataSource
    }
}

private extension AppDetailCollectionViewController
{
    func showPermissionAlert(for permission: AppPermission)
    {
        let alertController = UIAlertController(title: permission.localizedDisplayName, message: permission.localizedDescription, preferredStyle: .alert)
        alertController.addAction(.ok)
        self.present(alertController, animated: true)
    }
    
    func showUnknownEntitlementsAlert()
    {
        let alertController = UIAlertController(title: NSLocalizedString("Other Entitlements", comment: ""), message: NSLocalizedString("SideStore does not have detailed information for these entitlements.", comment: ""), preferredStyle: .alert)
        alertController.addAction(.ok)
        self.present(alertController, animated: true)
    }
}

extension AppDetailCollectionViewController
{
    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView
    {
        let headerView = self.collectionView.dequeueConfiguredReusableSupplementary(using: self.headerRegistration, for: indexPath)
        return headerView
    }
    
    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool
    {
        return false
    }
    
    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool
    {
        return false
    }
}
