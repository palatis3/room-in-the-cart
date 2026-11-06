import swift

from string kind, string name, int line, string detail
where
  exists(CompilerError error |
    kind = "compiler-error" and name = error.getText() and
    line = 0 and detail = "See retained extractor logs for location"
  )
  or
  exists(Expr expression, AnyGenericType type, GenericTypeDecl declaration |
    expression.getFile().getBaseName() = "PhotoProbe.swift" and
    type = expression.getType() and declaration = type.getDeclaration() and
    declaration.getName() = ["PhotosPicker", "PhotosPickerItem"] and
    kind = "resolved-expression" and name = declaration.getName() and
    line = expression.getLocation().getStartLine() and detail = type.toString()
  )
  or
  exists(TypeRepr representation, AnyGenericType type, GenericTypeDecl declaration |
    representation.getFile().getBaseName() = "PhotoProbe.swift" and
    type = representation.getType() and declaration = type.getDeclaration() and
    declaration.getName() = ["PhotosPicker", "PhotosPickerItem"] and
    kind = "resolved-type-reference" and name = declaration.getName() and
    line = representation.getLocation().getStartLine() and detail = type.toString()
  )
select kind, name, line, detail
