//
//  ACClient.swift
//  AssessmentCenter
//
//  Created by Raheel Sayeed on 13/02/18.
//  Copyright © 2018 Boston Children's Hospital. All rights reserved.
//

/*
 ? UTC, CST Dates? Difference?
 ? Can Participant/<> API sent back the FormID in Question?
 ? requestCompletion Handlers are not on the Main Thread
 - TODO:
 - Error Codes (AC Status)
 - Logging
*/

import Foundation

public typealias JSONDict = [String: Any]
typealias RequestBody = [String : String]


open class ACClient {
    
    
    static let keyAllForms = "Forms/.json"
    static let keyForm     = "Form"
	
    public var allForms: [ACForm]?
    private final let accessIdentifier : String
    private final let accessToken : String
    public  final let baseURL : URL
    
    public required init(baseURL base: URL, accessIdentifier: String, token: String) {
        self.accessIdentifier = accessIdentifier
        self.accessToken = token
        if base.absoluteString.last != "/" {
            self.baseURL = base.appendingPathComponent("/")
        } else {
            self.baseURL = base
        }
    }
    
    
    public convenience init(credentials: [String:String]) {
        let baseURLString = credentials["baseurl"]!
        let accessID      = credentials["accessidentifier"]!
        let accessToken   = credentials["accesstoken"]!
        self.init(baseURL: URL(string: baseURLString)!, accessIdentifier: accessID, token: accessToken)
    }
    
    private var authEncoded : String {
        get {
            return "\(accessIdentifier):\(accessToken)".base64encoded()
        }
    }
    private func defaultRequest(path:String, requestBody: RequestBody?)-> URLRequest {
        
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Basic \(authEncoded)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let requestBody = requestBody {
            var requestString = requestBody.reduce(into: String(), { (resultstring, arg) in
                let (key, value) = arg
                resultstring += "\(key)=\(value.URLEncoded())&"
            })
            requestString.removeLast(1)
            request.httpBody = requestString.data(using: .utf8)
        }
        return request

    }
    private func performRequest(path : String, requestBody: RequestBody?, completion: @escaping (_ response: JSONDict?, _ error: Error?) -> Void) {
        
        if path.isEmpty {
            print("No API Endpoint")
            return
        }
        print("Requesting.. \(path)")
        
        // ::: Should all operations in Queue be cancelled?
        let request = defaultRequest(path: path, requestBody: requestBody)
        
        let dataTask = URLSession.shared.dataTask(with: request) { (data, urlresponse, rerror) in            
            if let data = data {
                do {
                    let decodedJSON = try JSONSerialization.jsonObject(with: data, options: [])
                    if let decodedJSON = decodedJSON as? JSONDict {
                        completion(decodedJSON, nil)
                    }
                }
                catch {
                    completion(nil, error)
                }
            } else {
                completion(nil, rerror)
            }
        }
        
        dataTask.resume()
    }
    
    
    public func listForms(loinc: Bool = true, completion : ((_ forms: [ACForm]?)->Void)?) {
        let requestBody = (loinc) ? ["CODING_SYSTEM" : "LOINC"] : nil

        performRequest(path: ACClient.keyAllForms, requestBody: requestBody) { (responseJSON, error) in
            if let responseJSON = responseJSON, let list = responseJSON["Form"] as? [[String:String]] {
                let acForms : [ACForm] = list.map {
                    ACForm(_oid: $0["OID"]!, _title: $0["Name"]!, _loinc: $0["LOINC_NUM"])
                }
                self.allForms = acForms
                completion?(acForms)
            }
            else {
                if let error = error {
                    print(error.localizedDescription)
                }
                completion?(nil)
            }
            
            
        }
    }
    
    public func listBatteries(completion: ((_ batteries: [ACBattery]?) -> Void)?) {
        performRequest(path: "Batteries/.json", requestBody: nil) { (json, error) in
            if let json = json, let list = json["Battery"] as? [[String:String]] {
                print(list)
                let acBatteries : [ACBattery] = list.map { ACBattery($0["OID"]!, $0["Name"]!) }
                completion?(acBatteries)
            }
            if let error = error {
                print(error.localizedDescription)
            }
            completion?(nil)
        }
    }
    
    public func forms(from battery: ACBattery, completion: ((_ forms: [ACForm]?) -> Void)?) {
        
        let batteryEndpoint = "Batteries/\(battery.OID).json"
        performRequest(path: batteryEndpoint, requestBody: nil) { (json, error) in
            if let json = json, let list = json["Forms"] as? [[String:String]] {
                let acForms = list.map({ (form) -> ACForm in
                    let acform = ACForm(_oid: form["FormOID"]!, _title: form["Name"], _loinc: nil)
                    return acform
                })
                completion?(acForms)
            }
            
            if let error = error {
                print(error.localizedDescription)
            }
            completion?(nil)
        }
    }
    
    public func form(acform: ACForm, completion : (( _ form: ACForm? )-> Void)?) {

		let formEndpoint = "Forms/\(acform.OID).json"
        let requestBody =  ["CODING_SYSTEM" : "LOINC"]
        performRequest(path: formEndpoint, requestBody: requestBody) { (json, error) in
            if let json = json {
                
                
                acform.parse(from: json)
				completion?(acform.complete ? acform : nil)
            }
        }
    }
    
    public func form(OID: String, completion: ((_ form: ACForm?)->Void)?) {
        let acform = ACForm(_oid: OID, _title: nil, _loinc: nil)
        self.form(acform: acform, completion: completion)
    }
    
    public func forms(acforms: [ACForm], completion: ((_ completeForms: [ACForm]?) -> Void)) {
        var completedForms = [ACForm]()
        let semaphore = DispatchSemaphore(value: 0)
        for acForm in acforms {
            self.form(acform: acForm, completion: { (completedForm) in
                if let completedForm = completedForm {
                    completedForms.append(completedForm)
                }
                semaphore.signal()
            })
            semaphore.wait()
        }
		completion(completedForms.count > 0 ? completedForms : nil)
    }
    
    
    public func forms(formIdentifiers: [String], completion: ((_ completeForms: [ACForm]?) -> Void)){
        
        var completedForms = [ACForm]()
        let semaphore = DispatchSemaphore(value: 0)
        for formOID in formIdentifiers {
            self.form(OID: formOID, completion: { (completedForm) in
                if let completedForm = completedForm {
                    completedForms.append(completedForm)
                }
                semaphore.signal()
            })
            semaphore.wait()
        }
        completion(completedForms)
    }
    
    // MARK: Stateless API
    
    public func nextQ(form: ACForm, responses: [String: String]?, callback: ((_ newQuestion: QuestionForm?, _ error: Error?, _ concluded: Bool, _ score: ACScore?) -> Void)?) {
        let endpoint = "StatelessParticipants/\(form.OID).json"
        performRequest(path: endpoint, requestBody: responses) { (json, perror) in
            if let json = json, let items = json["Items"] as? [JSONDict] {
                if items.count == 1 {
                    let qForm = QuestionForm.create(from: items.first!)
                    callback?(qForm, nil, false, nil)
                }
                else {
                    let score = ACScore(from: json)
                    callback?(nil, nil, true, score)
                }
            } else {
                    callback?(nil, perror, false, nil)
            }
        }
    }
    
    // MARK: Sessions API
    
    public func beginSession(with form: ACForm, username: String?, expiration: Date?, completion : ((_ newSession : SessionItem?) -> Void)?) {
        let endpoint = "Assessments/\(form.OID).json"
        //TODO No custom expiration support yet.
        let requestBody = ["UID" : username] as? RequestBody
        performRequest(path: endpoint, requestBody: requestBody) { (json, error) in
            
            if let json = json, let oid = json["OID"] as? String {
                
                let expirationDate = Date.dateFormatter_UTC.date(from: json["Expiration"] as! String)
                let session = SessionItem(oid: oid, username: json["UID"] as? String, expiration: expirationDate!)
                completion?(session)
            }
            
        }
    }
    
    public func nextQuestion(sessionOID: String, responseItemOID: String?, responseValue: String?, completion : ((_ newQuestionForm : QuestionForm?, _ error: Error?, _ concluded: Bool, _ completionDate: Date?)->Void)?) {
        let endpoint = "Participants/\(sessionOID).json"
        let requestBody = ["ItemResponseOID": responseItemOID,
                             "Response" : responseValue] as? RequestBody
        self.performRequest(path: endpoint, requestBody: requestBody) { (json, rerror) in
            
            if let json = json, let formJSON = json["Items"] as? [JSONDict] {
                if let dateFinished = json["DateFinished"] as? String, !dateFinished.isEmpty {
                    let conclusionDate = Date.dateFormatter_CST.date(from: dateFinished)
                    completion?(nil, nil, true, conclusionDate)
                    return
                }
                let qForm = QuestionForm.create(from: formJSON.first! )
                completion?(qForm, nil, false, nil)
            }
            else {
                completion?(nil, nil, false, nil)
            }
        }
    }
    public func nextQuestion(session: SessionItem, responseItem: ResponseItem?, completion: ((_ newQuestionForm : QuestionForm?, _ error: Error?, _ concluded: Bool, _ completionDate: Date?)->Void)?) {
        nextQuestion(sessionOID: session.OID, responseItemOID: responseItem?.responseOID, responseValue: responseItem?.value, completion: completion)
        
    }
    
    public func score(session: SessionItem, completion: ((_ score : ACScore?, _ error : Error?)->Void)?) {
        let endpoint = "Results/\(session.OID).json"
        performRequest(path: endpoint, requestBody: nil) { (json, error) in
            if let json = json {
                let score = ACScore(from: json)
                completion?(score, nil)
            }
            else {
                print("Could Not Get the score")
                completion?(nil, nil)
            }
        }
    }
    
    
}


