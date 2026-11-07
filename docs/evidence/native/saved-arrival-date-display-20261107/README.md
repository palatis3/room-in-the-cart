# Show each saved arrival date

Installed a read-only localized Actual arrival row showing the saved receipt.receivedAt date and time. A newly opened form's current date no longer leaves the saved receipt time implicit. No receipt creation, validation, allocation, authority or clock behavior changes.

The exact three-line product addition compiled successfully in the retained run2 build. The complete English current-arrival/save/restart/calendar-observation case passed in160.032 seconds. Root viewed its actual after-restart screenshot: saved receipt arrival remains November7 at4:08AM, while the new form shows4:09AM. This verifies English saved-date rendering in the current-save path, not exact seconds, editing a past date or prevention of future time selection.

The full two-case invocation failed: native65/strict1,1pass/1fail, zero skips/runtime warnings. Spanish stopped at checkout source-field text selection in70.595 seconds, before arriving at this screen. Its actual screenshot/hierarchy shows Seleccionar and a paginated Adelante action; the scratch helper had assumed SelectAll was on the first menu page. That failure remains preserved and is being corrected separately. It does not establish Spanish arrival rendering. English/Spanish past/future controls and broader accessibility remain open.

Root verified exact compiled/installed product hashes and all retained source/product/original-result hashes. The owned simulator was deleted. Only the product row is installed; the scratch observer and selection helper are excluded. Proposal-manifest retains its original pre-validation status; installation.json and this record supersede that status. This is a scoped display improvement, not whole-app or release acceptance.
