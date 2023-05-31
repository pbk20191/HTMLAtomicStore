import CoreData
import Foundation

public class HTMLAtomicStore: NSAtomicStore {
    
    
    public class var storeType: String { "HTMLStore" }
    
    private var pDocument = XMLDocument(rootElement: nil)

    private var pRefDataToCacheNodeMap = [String:NSAtomicStoreCacheNode]()

    private let xmlOptions:XMLNode.Options = [.nodePreserveWhitespace, .nodePreserveCharacterReferences]

    public override var type: String { Self.storeType }

    public override var metadata: [String : Any]! {
        get {
            var readOnlyMeta = super.metadata ?? [:]
            readOnlyMeta[NSStoreTypeKey] = type
            return readOnlyMeta
        }
        set {
            super.metadata = newValue
        }
    }
    
    public override func load() throws {
        guard let fileURL = url else { return }
        if fileURL.isFileURL && !FileManager.default.fileExists(atPath: fileURL.path) {
            // maybe the file just doesn't exist, create it
            pDocument = XMLDocument(kind: .document, options: xmlOptions)
        } else {
            do {
                pDocument = try XMLDocument(contentsOf: fileURL, options: xmlOptions)
            } catch {
                // just create document if url is write only null directory
                if fileURL.absoluteString.hasSuffix("/dev/null") {
                    pDocument = XMLDocument(kind: .document, options: xmlOptions)
                } else {
                    throw error
                }
            }
        }
        loadDocumentMetadata()
        // if this is a new document, ensures that the head element is created before the body element
        let _ = self.headElement
        bodyElement.elements(forName: "table").forEach{ table in
            loadTable(table: table)
        }
        try pDocument.validate()
    }
    
    public override func save() throws {
        self.updateMetadata()
        try pDocument.validate()
        guard let fileURL = url else { return }
        if fileURL.isFileURL && !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        try pDocument.rootDocument?.xmlData()
            .write(to: fileURL, options: [.atomic])
    }

    /// Called by PSC during save to create cache nodes for newly inserted objects
    public override func newCacheNode(for managedObject: NSManagedObject) -> NSAtomicStoreCacheNode {
        let oid = managedObject.objectID
        let refData = referenceString(for: oid)
        // create the cache node
        let item = NSAtomicStoreCacheNode(objectID: oid)

        // create a new row in the table
        let table = table(for: managedObject.entity)
        let newRow = XMLElement(name: "tr")

        // give the table row an id
        let rowIDAttribute = XMLNode.attribute(withName: "id", stringValue: refData) as! XMLNode
        newRow.addAttribute(rowIDAttribute)

        // for each table header column, add a table data element
        let columnCount = table.child(at: 0)?.childCount ?? 1
        for _ in 0..<columnCount {
            newRow.addChild(XMLElement(name: "td"))
        }

        // finally add the new row
        table.addChild(newRow)

        // update the cache node's data
        updateCacheNode(item, from: managedObject)
        return item
    }

    // Called during save by the PSC to update the values of changed objects.
    // Also called during save by self to set the values of newly insert objects
    public override func updateCacheNode(_ node: NSAtomicStoreCacheNode, from managedObject: NSManagedObject) {
        let refData = referenceString(for: managedObject.objectID)

        guard let row = row(with: refData, inTable: nil) else {
            return
        }

        let headerNodes = (row.parent as? XMLElement)?.elements(forName: "tr").first?.elements(forName: "th") ?? []
        
        let columnNames = headerNodes.compactMap(\.stringValue)
        self.updateAttributesInCacheNode(node, and: row, from: managedObject, using: columnNames)
        self.updateRelationshipsInCacheNode(node, and: row, from: managedObject, using: columnNames)

    }

    // called when the PSC generates object IDs for our cachenodes
    // This method MUST return a new unique primary key reference data for an instance of entity. This
    // primary key value MUST be an id (String)
    public override func newReferenceObject(for managedObject: NSManagedObject) -> Any {
        let table = table(for: managedObject.entity)
        let newRow = newRow(for: managedObject.entity, in: table)
        // refData is the value of the id attribute
        return newRow.attribute(forName: "id")?.stringValue ?? ""
    }

    public override func willRemoveCacheNodes(_ cacheNodes: Set<NSAtomicStoreCacheNode>) {

        cacheNodes.forEach{ node in
            let table = table(for: node.objectID.entity)
            let refString = referenceString(for: node.objectID)
            let rowToDelete = row(with: refString, inTable: table)
            table.removeChild(at: rowToDelete!.index)
        }
    }

    // Gives the store a chance to do any non-dealloc teardown (for example, closing a network connection)
    // before removal.  Default implementation just does nothing.
    public override func willRemove(from coordinator: NSPersistentStoreCoordinator?) {
        pDocument = XMLDocument(rootElement: nil)
        super.willRemove(from: coordinator)
    }

    internal func indexes(of objects: [String], in array:[String]) -> IndexSet {
        var indexSet = IndexSet()
        objects.forEach{
            if let index = array.firstIndex(of: $0) {
                indexSet.insert(index)
            }
        }
        return indexSet
    }

    private func cacheNodes(for entity: NSEntityDescription, withReferenceData refData:String) -> NSAtomicStoreCacheNode {
        if let item = pRefDataToCacheNodeMap[refData] {
            return item
        } else {
            let oid = objectID(for: entity, withReferenceString: refData)
            let item = NSAtomicStoreCacheNode(objectID: oid)
            pRefDataToCacheNodeMap[refData] = item
            return item
        }
    }

    internal func row(with refData:String, inTable contextNode:XMLElement?) -> XMLElement? {
        let baseString:String
        let node:XMLElement
        if let contextNode {
            baseString =  "tr[@id=\"%@\"]"
            node = contextNode
        } else {
            baseString = "/html/body/table/tr[@id=\"%@\"]"
            node = pDocument.rootElement()!
        }
        let xPath = String(format: baseString, refData)
        do {
            return try node.nodes(forXPath: xPath).compactMap{ $0 as? XMLElement }.first
        } catch {
            print(error)
            return nil
        }
    }

    /// returns the nodes of the relationship filled out by columnData. Will be a single cache node if relationship is to-one and a set of cache nodes if relatinoship is to-many
    private func cacheNodesForRelationShipData( _ columnData: XMLElement, and relationShip:NSRelationshipDescription, from table:XMLElement) -> RelationCache {
        var results = Set<NSAtomicStoreCacheNode>()
        let links = columnData.elements(forName: "a")
        if !relationShip.isToMany {
            precondition(links.count <= 1, "More than one destination object described for to-one relationship \(relationShip.name)")
        }
        links.forEach{ link in
            var destinationID = link.attribute(forName: "href")?.objectValue as? NSString
            precondition(destinationID != nil && destinationID!.length > 1)
            destinationID = destinationID!.substring(from: 1) as NSString

            let newObject = cacheNodes(for: relationShip.destinationEntity!, withReferenceData: destinationID! as String)
            results.insert(newObject)
        }
        if !relationShip.isToMany {
            return .One(results.randomElement().unsafelyUnwrapped)
        } else {
            return .Many(results)
        }
    }

    private enum RelationCache {
        case One(NSAtomicStoreCacheNode)
        case Many(Set<NSAtomicStoreCacheNode>)
    }

    internal let dateFormatter:DateFormatter = {
       let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()



    internal func loadTable(table: XMLElement) {
        let entityName = table.attribute(forName: "class")?.stringValue
        guard let entityName, let entity = persistentStoreCoordinator?.managedObjectModel.entitiesByName[entityName] else { return }
        let attributes = entity.attributesByName
        let relationships = entity.relationshipsByName

        // get the available column names
        let allRows = table.elements(forName: "tr")
        let columnNames = allRows.first?.elements(forName: "th").compactMap(\.stringValue) ?? []

        // get the attribute and relationship names
        let attributesNames = attributes.keys.map{ $0 }
        let relationshipNames = relationships.keys.map{ $0 }

        // convert everything to be in terms of the column ordering and column names

        // get the indexes of columns with attribute data
        let attributeIndexes = indexes(of: attributesNames, in: columnNames)

        // get the indexes of columns with relationship data
        let relationshipIndexes = indexes(of: relationshipNames, in: columnNames)
        var results:Set<NSAtomicStoreCacheNode> = []
        var lastIndex = 1
        allRows.forEach{ row in
            let rowData = row.elements(forName: "td")
            if rowData.count > 0 {
                // the first row will not have any rowdata - it's a th row

                // get the row id
                let rowID = row.attribute(forName: "id")
                let refData:String = {
                    if let ref = rowID?.stringValue {
                        return ref
                    } else {
                        // if there wasn't an id, make one up.
                        while true {
                            let ref = String(format: "%@_%@", entityName, lastIndex)
                            lastIndex += 1
                            if self.row(with: ref, inTable: table) != nil {
                                continue
                            } else {
                                rowID?.objectValue = ref
                                return ref
                            }
                        }
                    }
                }()

                // create the cache node to register
                let item = cacheNodes(for: entity, withReferenceData: refData)

                // set attribute values
                attributeIndexes.forEach{ index in
                    let columnData = rowData[index]
                    var objectValue = columnData.objectValue
                    let attributeName = columnNames[index]

                    let attribute = attributes[attributeName].unsafelyUnwrapped
                    switch attribute.attributeType {
                    case .decimalAttributeType:
                        objectValue = NSDecimalNumber(string: objectValue as? String)
                    case .doubleAttributeType:
                        objectValue = (objectValue as? NSString)?.doubleValue as? NSNumber
                    case .floatAttributeType:
                        objectValue = (objectValue as? NSString)?.floatValue as? NSNumber
                    case .booleanAttributeType:
                        objectValue = (objectValue as? NSString)?.boolValue as? NSNumber
                    case .dateAttributeType:
                        if let string = objectValue as? String {
                            objectValue = ISO8601DateFormatter().date(from: string) as NSDate?
                        } else {
                            objectValue = attribute.defaultValue
                        }
                    case .binaryDataAttributeType:

                        // if this element has children, maybe it's an <a href> instead of inline junk
                        if
                            columnData.childCount == 1,
                            let content = columnData.child(at: 0) as? XMLElement,
                            content.name == "a" {
                            if let hrefValue = content.attribute(forName: "href")?.objectValue as? String, let refURL = URL(string: hrefValue) {
                                do {
                                    objectValue = try Data(contentsOf: refURL)
                                } catch {
                                    print(#file, #line, error)
                                }

                            }

                        } else {
                            // we have to do this in order to decode the base64 value of the data attribute into an NSData. Using openSSL is the only "free" way we have to decode base64
                            objectValue = (columnData.child(at: 0) as? XMLElement)?.attribute(forName: "data")?.objectValue
                            let decoded = {
                                if let string = objectValue as? String {
                                    return Data.init(base64Encoded: string)
                                } else {
                                    return nil
                                }
                            }()
                            objectValue = decoded
                        }
                        break
                    case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
                        objectValue = (objectValue as? NSString)?.integerValue as NSNumber?
                    default:
                        break
                    }
                    item.setValue(objectValue, forKey: attributeName)
                }

                // set relationships values
                relationshipIndexes.forEach{ index in
                    let columnData = rowData[index]

                    let destinationCacheNodes = self.cacheNodesForRelationShipData(columnData, and: relationships[columnNames[index]].unsafelyUnwrapped, from: table)
                    switch destinationCacheNodes {
                    case .Many(let many):
                        item.setValue(many, forKey: columnNames[index])
                    case .One(let single):
                        item.setValue(single, forKey: columnNames[index])
                    }
                }
                results.insert(item)
            }
            self.addCacheNodes(results)
        }
    }

    private func loadDocumentMetadata() {
        var dictionary = [String:Any]()
        headElement.children?.forEach{
            guard let metaElement = $0 as? XMLElement,
                  let metaName = metaElement.attribute(forName: "name")?.stringValue else { return }

            // we'll always try to do propertyList processing since that's what we'll usually want
            var metaContent = metaElement.attribute(forName: "content")?.objectValue
            if let plainString = metaContent as? String {
                do {
                    
                    metaContent = try PropertyListSerialization.propertyList(from: Data(plainString.utf8), format: nil)
                } catch {
                    print(error)
                }
            }

            dictionary[metaName] = metaContent

        }
        self.metadata = dictionary
    }

    // updates the NSXMLDocument's HTML meta tags
    private func updateMetadata() {
        let head = headElement
        // attempt to preserve non-meta lements in the head element - only delete meta elements
        for index in stride(from: head.childCount, to: 0, by: -1) {
            if let element = head.child(at: index-1), element.name == "meta" {
                head.removeChild(at: index-1)
            }
        }
        let dictionary = metadata ?? [:]
        dictionary.keys.forEach{ name in
            let metaElement = XMLElement(name: "meta")
            var attribute = XMLNode.attribute(withName: "name", stringValue: name) as! XMLNode
            metaElement.addAttribute(attribute)
            if let value = dictionary[name] {
                attribute = XMLNode.attribute(withName: "content", stringValue: "\(value)") as! XMLNode
            } else {
                attribute = XMLNode.attribute(withName: "content", stringValue: "null") as! XMLNode
            }
            //    [attribute setObjectValue:[metadata objectForKey:name]]; // use setObject value to ensure we get escaping
            metaElement.addAttribute(attribute)
            head.addChild(metaElement)
        }
    }

    private func updateAttributesInCacheNode(_ node:NSAtomicStoreCacheNode, and row:XMLElement, from managedObject:NSManagedObject, using columnNames: [String]) {
        let attributeKeys = managedObject.entity.attributesByName.keys.map{ $0 }
        let indexSet = indexes(of: attributeKeys, in: columnNames)
        indexSet.forEach{ index in
            let name = columnNames[index]
            let columnData = row.child(at: index)
            let attribute = managedObject.entity.attributesByName[name]!
            let attributeType = attribute.attributeType
            let valueToStore = managedObject.value(forKey: name)
            var content:XMLElement?
            switch attributeType {
            case .floatAttributeType:
                content = XMLElement(
                    name: "pre",
                    stringValue: (valueToStore as? NSNumber)?.stringValue
                )
            case .binaryDataAttributeType:
                var writeBytes = true
                if columnData?.childCount == 1 {
                    content = columnData?.child(at: 0) as? XMLElement
                }

                // if the original content was a link, don't just overwrite it. Try to write data back to the url first.
                if
                    let content, content.name == "a",
                    let hrefValue = content.attribute(forName: "href")?.objectValue as? String,
                    let url = URL(string: hrefValue),
                    let data = valueToStore as? Data
                {
                    do {
                        try data.write(to: url, options: [.atomic])
                        writeBytes = false
                    } catch {
                        print(error)
                    }
                }
                if writeBytes {
                    // setting up the node this way encodes the NSData as bsae64 in data attribute

                    content = XMLElement(name: "object")
                    let dataAttribute = XMLNode.attribute(withName: "data", stringValue: "") as! XMLNode
                    dataAttribute.stringValue = nil
                    dataAttribute.objectValue = valueToStore
                    content?.addAttribute(dataAttribute)
                    content?.stringValue = "binary object value"
                }
            case .dateAttributeType:
                if let date = valueToStore as? Date {
                    content = XMLElement(name: "pre")
                    content?.stringValue = ISO8601DateFormatter().string(from: date)
                }
            default:
                content = XMLElement(name: "pre")
                content?.objectValue = valueToStore
            }
            (columnData as? XMLElement)?.setChildren([content].compactMap{ $0 })
        }

        node.setValuesForKeys(managedObject.dictionaryWithValues(forKeys: attributeKeys))
    }

    private func updateRelationshipsInCacheNode(_ node:NSAtomicStoreCacheNode, and row:XMLElement, from managedObject:NSManagedObject, using columnNames: [String]) {
        let relationshipsByName = managedObject.entity.relationshipsByName
        let indexSet = indexes(of: relationshipsByName.keys.map{ $0 }, in: columnNames)
        indexSet.forEach{ index in
            let name = columnNames[index]
            let columnData = row.child(at: index) as? XMLElement
            columnData?.setChildren(nil)
            let relatedObjects:Set<NSManagedObject>
            var relatedCacheNodes = Set<NSAtomicStoreCacheNode>()
            if relationshipsByName[name]?.isToMany == false, let relatedObject = managedObject.value(forKey: name) as? NSManagedObject {
                //if this is a to-One relationship, relatedObjects will be a managedObject, not a set
                relatedObjects = [relatedObject]
            } else if relationshipsByName[name]?.isToMany == true, let relatated = managedObject.value(forKey: name) as? Set<NSManagedObject> {
                relatedObjects = relatated
            } else {
                relatedObjects = []
            }

            // <a href="#Entity2_4">Entity2_4</a>
            relatedObjects.forEach{ destinationObject in

                let refData = referenceString(for: destinationObject.objectID)
                let destinationNode = cacheNodes(for: destinationObject.entity, withReferenceData: refData)
                relatedCacheNodes.insert(destinationNode)
                let linkNode = XMLElement(name: "a")
                let hrefString = String(format: "#%@", refData)
                let hrefAttribute = XMLElement.attribute(withName: "href", stringValue: hrefString) as! XMLElement
                linkNode.addAttribute(hrefAttribute)
                linkNode.objectValue = hrefString
                columnData?.addChild(linkNode)
            }
            node.setValue(relatedCacheNodes, forKey: name)
        }
    }

    // creates a new row based on entity and the peer rows that already exist in table. callers have to add it to the table.
    private func newRow(for entity:NSEntityDescription, in table:XMLElement) -> XMLElement {
        let row = XMLElement(name: "r")

        // id = @"entityname_uniquenumber"
        let idString = entity.name.unsafelyUnwrapped

        // does the table have a unique last number attribute?
        let nexIDAttribute:XMLNode = {
            if let node = table.attribute(forName: "nextid") {
                return node
            } else {

                let node = XMLNode.attribute(withName: "nextid", stringValue: "") as! XMLNode
                node.stringValue = nil
                table.addAttribute(node)
                return node
            }
        }()
        var nextIDValue:String = nexIDAttribute.stringValue ?? ""
        var nextID:Int
        if let nextIDString = nexIDAttribute.stringValue {
            nextID = (nextIDString as NSString).integerValue
            nextIDValue = String(format: "%@_%ld", idString, nextID)
        } else {
            // make one up
            let lastRow = table.elements(forName: "tr").last
            nextID = (lastRow?.attribute(forName: "id")?.stringValue as NSString?)?.integerValue ?? 0

            while true {
                nextIDValue = String(format: "%@_%ld", idString, nextID)
                let row = self.row(with: nextIDValue, inTable: table)
                if row == nil || nextID == NSNotFound {
                    break
                }
                nextID += 1
            }
        }
        precondition(nextID != NSNotFound, "blew past some limit trying to find an unused id for a new row")
        // nextIDValue is our new id
        nextID += 1
        nexIDAttribute.objectValue = String(format: "%ld", nextID)
        let rowIDAttribute:XMLNode = {
            if let node = row.attribute(forName: "id") {
                return node
            } else {
                let node = XMLNode.attribute(withName: "id", stringValue: "") as! XMLNode
                node.stringValue = nil
                row.addAttribute(node)
                return node
            }
        }()

        rowIDAttribute.objectValue = nextIDValue

        // add the table datas
        let headerCount = table.elements(forName: "tr").first?.childCount ?? 0
        for _ in stride(from: 0, to: headerCount, by: 1) {
            row.addChild(XMLElement(name: "td"))
        }
        return row
    }

    private var htmlEnvelope:XMLElement {
        if let envelope = pDocument.rootElement() {
            return envelope
        } else {
            let envelope = XMLElement(name: "html")
            let namespaceAttribute = XMLNode.attribute(withName: "xmlns", stringValue: "http://www.w3.org/1999/xhtml") as! XMLNode
            pDocument.setRootElement(envelope)
            envelope.addAttribute(namespaceAttribute)
            return envelope
        }
    }

    private func rootElement(with name:String) -> XMLElement {
        let htmlEnvelope = self.htmlEnvelope
        if let result = htmlEnvelope.elements(forName: name).last {
            return result
        } else {

            let child = XMLElement(name: name)
            htmlEnvelope.addChild(child)
            return child
        }
    }

    private var headElement:XMLElement {
        rootElement(with: "head")
    }

    private var bodyElement:XMLElement {
        rootElement(with: "body")
    }

    private func table(for entity:NSEntityDescription) -> XMLElement {

        // find the table to insert the new object into
        let entityName = entity.name.unsafelyUnwrapped
        let xpath = String(format: "/html/body/table[@class=\"%@\"]", entityName)
        let nodes:[XMLNode]
        do {
            nodes = (try pDocument.rootElement()?.nodes(forXPath: xpath)) ?? []
        } catch {
            print(error)
            nodes = []
        }
        precondition(nodes.count <= 1, "multiple tables for entity \(entityName) found")
        let table:XMLElement
        if let nodeTable = nodes.first as? XMLElement, nodes.count == 1 {
            table = nodeTable
        } else {
            table = XMLElement(name: "table")
            let tableHeaderRow = XMLElement(name: "tr")
            entity.properties.forEach{ property in
                if !property.isTransient {
                    tableHeaderRow.addChild(XMLElement(name: "th", stringValue: property.name) )
                }
            }
            let tableClassAttribute:XMLNode = XMLNode.attribute(withName: "class", stringValue: entity.name!) as! XMLNode
            table.addAttribute(tableClassAttribute)
            table.addChild(tableHeaderRow)
            let body = self.bodyElement
            body.addChild(table)
        }
        return table
    }


    private func referenceString(for objectID: NSManagedObjectID) -> String {
        referenceObject(for: objectID) as! String
    }

    private func objectID(for entity: NSEntityDescription, withReferenceString data: String) -> NSManagedObjectID {
        objectID(for: entity, withReferenceObject: data)
    }

    private func newReferenceString(for managedObject: NSManagedObject) -> String {
        self.newReferenceObject(for: managedObject) as! String
    }
    
}
