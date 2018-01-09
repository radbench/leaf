import Async
import Dispatch
import Foundation

/// Serializes parsed Leaf ASTs into view bytes.
public protocol TemplateSerializer: Worker {
    var ast: [TemplateSyntax] { get }
    var context: TemplateContext { get }
    func render(_ syntax: TagSyntax) -> Future<TemplateData>
    func subSerializer(for ast: [TemplateSyntax]) -> Self
}

extension TemplateSerializer {
    /// Serializes the AST into Bytes.
    public func serialize() -> Future<View> {
        var parts: [Future<Data>] = []

        for syntax in ast {
            let promise = Promise(Data.self)
            switch syntax.type {
            case .raw(let data):
                promise.complete(data)
            case .tag(let name, let parameters, let body, let chained):
                renderTag(
                    name: name,
                    parameters: parameters,
                    body: body,
                    chained: chained,
                    source: syntax.source
                ).do { context in
                    guard let data = context.data else {
                        promise.fail(TemplateSerializerError.unexpectedTagData(name: name, source: syntax.source))
                        return
                    }

                    promise.complete(data)
                }.catch { error in
                    promise.fail(error)
                }
            default:
                promise.fail(TemplateSerializerError.unexpectedSyntax(syntax))
            }
            parts.append(promise.future)
        }

        return parts.map(to: View.self) { data in
            return View(data: Data(data.joined()))
        }
    }

    // MARK: private

    // renders a tag using the supplied context
    private func renderTag(
        name: String,
        parameters: [TemplateSyntax],
        body: [TemplateSyntax]?,
        chained: TemplateSyntax?,
        source: TemplateSource
    ) -> Future<TemplateData> {
        return Future<TemplateData> {
            let inputFutures: [Future<TemplateData>] = parameters.map { parameter in
                let inputPromise = Promise(TemplateData.self)
                self.resolveSyntax(parameter).do { input in
                    inputPromise.complete(input)
                }.catch { error in
                    inputPromise.fail(error)
                }
                return inputPromise.future
            }

            return inputFutures.flatMap(to: TemplateData.self) { inputs in
                let tag = TagSyntax(
                    name: name,
                    parameters: inputs,
                    body: body,
                    source: source,
                    on: self
                )
                return self.render(tag)
            }.flatMap(to: TemplateData.self) { data in
                switch data {
                case .null:
                    guard let chained = chained else {
                        return Future(.null)
                    }
                    switch chained.type {
                    case .tag(let name, let params, let body, let c):
                        return self.renderTag(
                            name: name,
                            parameters: params,
                            body: body,
                            chained: c,
                            source: chained.source
                        )
                    default: throw TemplateSerializerError.unexpectedSyntax(chained)
                    }
                default: return Future(data)
                }
            }
        }
    }

    // resolves a constant to data
    private func resolveConstant(_ const: TemplateConstant) -> Future<TemplateData> {
        let promise = Promise(TemplateData.self)
        switch const {
        case .bool(let bool):
            promise.complete(.bool(bool))
        case .double(let double):
            promise.complete(.double(double))
        case .int(let int):
            promise.complete(.int(int))
        case .string(let ast):
            subSerializer(for: ast).serialize().do { view in
                promise.complete(.data(view.data))
            }.catch { error in
                promise.fail(error)
            }
        }
        return promise.future
    }

    // resolves an expression to data
    private func resolveExpression(_ op: ExpressionInfixOperator, left: TemplateSyntax, right: TemplateSyntax) -> Future<TemplateData> {
        let l = resolveSyntax(left)
        let r = resolveSyntax(right)

        let promise = Promise(TemplateData.self)

        switch op {
        case .equal:
            return l.flatMap(to: TemplateData.self) { l in
                return r.map(to: TemplateData.self) { r in
                    return .bool(l == r)
                }
            }
        case .notEqual:
            l.do { l in
                r.do { r in
                    promise.complete(.bool(l != r))
                    }.catch { error in
                        promise.fail(error)
                }
                }.catch { error in
                    promise.fail(error)
            }
        case .and:
            l.do { l in
                r.do { r in
                    promise.complete(.bool(l.bool != false && r.bool != false))
                    }.catch { error in
                        promise.fail(error)
                }
                }.catch { error in
                    promise.fail(error)
            }
        case .or:
            r.do { r in
                l.do { l in
                    promise.complete(.bool(l.bool != false || r.bool != false))
                    }.catch { error in
                        promise.fail(error)
                }
                }.catch { error in
                    promise.fail(error)
            }
        default:
            l.do { l in
                r.do { r in
                    if let leftDouble = l.double, let rightDouble = r.double {
                        switch op {
                        case .add:
                            promise.complete(.double(leftDouble + rightDouble))
                        case .subtract:
                            promise.complete(.double(leftDouble - rightDouble))
                        case .greaterThan:
                            promise.complete(.bool(leftDouble > rightDouble))
                        case .lessThan:
                            promise.complete(.bool(leftDouble < rightDouble))
                        case .multiply:
                            promise.complete(.double(leftDouble * rightDouble))
                        case .divide:
                            promise.complete(.double(leftDouble / rightDouble))
                        default:
                            promise.complete(.bool(false))
                        }
                    } else {
                        promise.complete(.bool(false))
                    }
                }.catch { error in
                    promise.fail(error)
                }
            }.catch { error in
                promise.fail(error)
            }
        }

        return promise.future
    }

    // resolves syntax to data (or fails)
    private func resolveSyntax(_ syntax: TemplateSyntax) -> Future<TemplateData> {
        let promise = Promise(TemplateData.self)

        switch syntax.type {
        case .constant(let constant):
            resolveConstant(constant).do { data in
                promise.complete(data)
            }.catch { error in
                promise.fail(error)
            }
        case .expression(let expr):
            switch expr {
            case .infix(let op, let left, let right):
                resolveExpression(op, left: left, right: right).do { data in
                    promise.complete(data)
                    }.catch { error in
                        promise.fail(error)
                }
            case .prefix(let op, let right):
                switch op {
                case .not:
                    switch right.type {
                    case .identifier(let id):
                        let promise = Promise(TemplateData.self)
                        contextFetch(path: id).do { data in
                            promise.complete(.bool(data.bool == true))
                        }.catch { error in
                            promise.fail(error)
                        }
                    case .constant(let c):
                        switch c {
                        case .bool(let bool):
                            promise.complete(.bool(!bool))
                        case .double(let double):
                            promise.complete(.bool( double != 1))
                        case .int(let int):
                            promise.complete(.bool(int != 1))
                        case .string(_):
                            promise.fail(TemplateSerializerError.unexpectedSyntax(syntax))
                        }
                    default:
                        promise.fail(TemplateSerializerError.unexpectedSyntax(syntax))
                    }
                }
            case .postfix:
                fatalError()
            }
        case .identifier(let id):
            contextFetch(path: id).do { value in
                promise.complete(value)
            }.catch { error in
                promise.fail(error)
            }
        case .tag(let name, let parameters, let body, let chained):
            return renderTag(
                name: name,
                parameters: parameters,
                body: body,
                chained: chained,
                source: syntax.source
            )
        default:
            promise.fail(TemplateSerializerError.unexpectedSyntax(syntax))
        }

        return promise.future
    }

    // fetches data from the context
    private func contextFetch(path: [String]) -> Future<TemplateData> {
        var promise = Promise(TemplateData.self)

        var current = context.data
        var iterator = path.makeIterator()

        func handle(_ path: String) {
            switch current {
            case .dictionary(let dict):
                if let value = dict[path] {
                    current = value
                    if let next = iterator.next() {
                        handle(next)
                    } else {
                        promise.complete(current)
                    }
                } else {
                    promise.complete(.null)
                }
            case .future(let fut):
                fut.do { value in
                    current = value
                    handle(path)
                    }.catch { error in
                        promise.fail(error)
                }
            default:
                promise.complete(.null)
            }
        }

        if let first = iterator.next() {
            handle(first)
        } else {
            promise.complete(current)
        }

        return promise.future
    }
}


