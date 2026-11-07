# Explicit product-tar exception proposal

Parent-authorized scratch proposal, requiring independent review before installation. This changes only the compiled-product tar validator. It grants no result-artifact or result-download exception.

Exact member: `Products/Debug-iphonesimulator/RoomInTheCart.app/RoomInTheCart.debug.dylib`.

Only a regular file at that exact archive spelling receives the exclusive `<80,000,000` byte bound. A symlink, directory, hard link, alias, different app/configuration/name/case, or any other member retains the existing exclusive `<50,000,000` bound. Existing extraction type/path/parent/symlink checks still apply independently; matching this path does not waive them. Values at80,000,000 are refused.

Rationale: the parent measured52,752,832 bytes for this dylib in the local generic simulator build with ordinary Debug plus the diagnostic flag, Xcode27.1. That build's Products contained149,056,492 bytes in179 regular files. This is evidence that the original50MB result-member bound does not fit this measured compiled product. It is not a prediction of hosted Xcode26.3 size or behavior. No hosted artifact has been downloaded to justify a further exception; exceeding80MB remains a refusal requiring separate review.

Builder SHA256 remains checked before extraction. Compressed archive<256,000,000 bytes, total<1,000,000,000 bytes, count<50,000, expansion ratio<=1000, all other member limits, fresh destination, exact source/product hashes, and all safe-path/type rules remain unchanged. The original result/download policies remain unchanged.
