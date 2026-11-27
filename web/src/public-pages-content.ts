// Source-based English and US-Spanish draft copy. Human language, operator
// policy/terms and production retention review remain release requirements.
export type PublicLanguage = 'en' | 'es';
export type PublicPageKey = 'help' | 'privacy' | 'terms' | 'support';
export type PublicCopy = Readonly<Record<PublicLanguage, string>>;
export type PublicPage = Readonly<{ title: PublicCopy; lead: PublicCopy; notice: PublicCopy | null;
  sections: readonly Readonly<{ id?: string; title: PublicCopy; paragraphs: readonly PublicCopy[] }>[] }>;

export const publicPages = {
  "help": {
    "title": {
      "en": "Help",
      "es": "Ayuda"
    },
    "lead": {
      "en": "On your iPhone, open Shop and use Add a grocery to start your private list. In a browser, open your household invitation to send a request or read shared cooking instructions.",
      "es": "En tu iPhone, abre Compras y usa Agregar un producto para empezar tu lista privada. En un navegador, abre la invitación de tu hogar para enviar una solicitud o leer las instrucciones de cocina compartidas."
    },
    "notice": null,
    "sections": [
      {
        "title": {
          "en": "Invited browser access",
          "es": "Acceso por invitación en el navegador"
        },
        "paragraphs": [
          {
            "en": "The browser’s household features are for invited contributors and cooks. Open the invitation or current-view link your household gave you. Sign-in, household membership and the selected view are checked separately. If email sign-in or guardian consent is unavailable, the page says so; it does not create access.",
            "es": "Las funciones del hogar en el navegador son para colaboradores y personas que cocinan con invitación. Abre el enlace de invitación o de vista actual que te dio tu hogar. El inicio de sesión, la pertenencia al hogar y la vista seleccionada se verifican por separado. Si el inicio de sesión por correo o el consentimiento del tutor no está disponible, la página lo indica; no crea acceso."
          },
          {
            "en": "Review a request before sending. Received means the household service has your request. The shopper decides whether to add it to the pickup. Waiting to send means the browser still has it in its local queue. Retry an uncertain submission with the original retry action rather than sending a duplicate. A cook with permission can suggest a correction; only the shopper can approve a basket change.",
            "es": "Revisa una solicitud antes de enviarla. Recibida significa que el servicio del hogar tiene tu solicitud. Quien hace las compras decide si la agrega a la recogida. Pendiente de enviar significa que la solicitud sigue en la cola local del navegador. Si un envío no tiene resultado confirmado, usa la acción de reintento original en vez de enviar un duplicado. Quien cocina con permiso puede sugerir una corrección; solo la persona asignada para comprar puede aprobar un cambio en la cesta."
          },
          {
            "en": "Unsent browser text stays on the open page unless an enrolled contributor separately agrees to the permitted local queue. Closing or reloading can lose unsent text. Received requests and suggestions can be recovered from the service only while that same access remains valid. Sign out before sharing a browser.",
            "es": "El texto del navegador sin enviar permanece en la página abierta, salvo que un colaborador inscrito acepte por separado la cola local permitida. Cerrar o recargar puede perder el texto sin enviar. Las solicitudes y sugerencias recibidas se pueden recuperar del servicio solo mientras siga vigente ese mismo acceso. Cierra sesión antes de compartir un navegador."
          }
        ]
      },
      {
        "title": {
          "en": "Compare two packs",
          "es": "Comparar dos paquetes"
        },
        "paragraphs": [
          {
            "en": "Open Compare packs in Shop. Enter the amount you need, the usable amount in each pack and the price. If the package uses a different kind of unit, enter two equivalent amounts from its label or your own measurement, such as 120 grams of this flour for 1 cup. Without that information, leave the conversion blank.",
            "es": "Abre Comparar paquetes en Compras. Ingresa la cantidad que necesitas, la cantidad aprovechable de cada paquete y su precio. Si el paquete usa otro tipo de unidad, ingresa dos cantidades equivalentes de la etiqueta o de una medición propia, por ejemplo, 120 gramos de esa harina por 1 taza. Si no tienes ese dato, deja la conversión en blanco."
          },
          {
            "en": "Review the whole packs needed, the usable food and the cost. An unknown usable amount or missing price stays unresolved. Save the comparison to reopen it in Records.",
            "es": "Revisa los paquetes completos necesarios, la comida aprovechable y el costo. Si la cantidad aprovechable es desconocida o falta un precio, el resultado sigue sin resolverse. Guarda la comparación para volver a abrirla en Historial."
          },
          {
            "en": "A pack comparison covers that item only. To judge the whole pickup, review the shopping list and its checkout costs.",
            "es": "La comparación de paquetes abarca solo ese artículo. Para evaluar toda la recogida, revisa la lista de compra y sus costos al pagar."
          }
        ]
      },
      {
        "title": {
          "en": "Build a list and check the budget",
          "es": "Crear una lista y revisar el presupuesto"
        },
        "paragraphs": [
          {
            "en": "In Shop, open your shopping list. Type items or review pasted text before adding it. Review possible duplicates; meal needs and everyday staples remain separate.",
            "es": "En Compras, abre tu lista de compra. Escribe artículos o revisa el texto pegado antes de agregarlo. Revisa los posibles duplicados; las necesidades de las comidas y los productos habituales se mantienen separados."
          },
          {
            "en": "Set a spending cap and review the expected checkout with known fees, taxes and discounts. Missing prices remain visible. A payment hold and a posted charge are separate amounts.",
            "es": "Establece un límite de gasto y revisa el total previsto con las tarifas, impuestos y descuentos conocidos. Los precios que faltan siguen visibles. Una retención de pago y un cargo contabilizado son cantidades separadas."
          },
          {
            "en": "To compare stores, enter two quotes for the same needs. Include fees, extra travel cost and time, and check when each quote was observed. This is a manual comparison, not live retailer pricing.",
            "es": "Para comparar tiendas, ingresa dos cotizaciones para las mismas necesidades. Incluye las tarifas, el costo adicional del viaje y el tiempo, y revisa cuándo se observó cada cotización. Es una comparación manual; no son precios de la tienda en tiempo real."
          }
        ]
      },
      {
        "title": {
          "en": "Plan dinners and protect lunches",
          "es": "Planificar cenas y reservar almuerzos"
        },
        "paragraphs": [
          {
            "en": "In Dinners, save a familiar meal with its portions, ingredients, source, exclusions and any known prep lead time. Review an idea before choosing it for this shop. Choosing an idea and assigning a night are separate steps.",
            "es": "En Cenas, guarda una comida conocida con sus porciones, ingredientes, fuente, exclusiones y cualquier tiempo de preparación previo conocido. Revisa una idea antes de elegirla para esta compra. Elegir una idea y asignarle una noche son pasos separados."
          },
          {
            "en": "In Dinners, choose Paste a recipe to review and save a note. Under Import and use recipes, you can also type a recipe or choose a Recipe JSON-LD file. When you have a pickup, open a saved recipe to choose which ingredients to add.",
            "es": "En Cenas, elige Pegar una receta para revisar y guardar una nota. En Importar y usar recetas también puedes escribir una receta o elegir un archivo Recipe JSON-LD. Cuando tengas una recogida, abre una receta guardada y elige qué ingredientes agregar."
          },
          {
            "en": "Open a planned dinner to change its day or servings. Review the ingredient amounts before saving. Your original recipe keeps its servings. Use the meal week for guests, nights away and lunches to set aside.",
            "es": "Abre una cena programada para cambiar el día o las porciones. Revisa las cantidades de los ingredientes antes de guardar. La receta original conserva sus porciones. Usa la semana de comidas para planificar visitas, noches fuera y almuerzos que quieras apartar."
          },
          {
            "en": "Count pantry or freezer food only after confirming its usable quantity and matching it to the need. If food falls short, protect lunch reservations and review each affected dinner. Leave an unresolved need open until you choose a repair.",
            "es": "Cuenta la comida de la despensa o del congelador solo después de confirmar su cantidad aprovechable y vincularla con la necesidad. Si falta comida, protege las reservas para el almuerzo y revisa cada cena afectada. Deja abierta una necesidad sin resolver hasta elegir una solución."
          }
        ]
      },
      {
        "title": {
          "en": "Hand off a pickup and record what arrived",
          "es": "Compartir la lista de recogida y registrar lo que llegó"
        },
        "paragraphs": [
          {
            "en": "Review the basket and prepare a dated retailer handoff in Shop. Copy or share that reviewed list, then place the order with your retailer. Copying or sharing does not place an order.",
            "es": "Revisa la cesta y prepara una lista con fecha para la tienda en Compras. Copia o comparte esa lista revisada y luego realiza el pedido en tu tienda. Copiar o compartir no realiza un pedido."
          },
          {
            "en": "Report placement separately. Record substitutions and the usable quantities that actually came home, then review meal shortages. Keep a pending credit pending until it posts; do not record a refund twice.",
            "es": "Registra por separado que realizaste el pedido. Anota las sustituciones y las cantidades aprovechables que llegaron a casa, y luego revisa lo que falta para las comidas. Mantén pendiente un crédito hasta que se contabilice; no registres un reembolso dos veces."
          },
          {
            "en": "Prepare a dated cook instruction showing portions, what to set aside and what remains unresolved. Choose the recipient language and review any private wording. Marking a copy sent and reporting acknowledgment are separate actions.",
            "es": "Prepara una instrucción con fecha para quien cocina que muestre las porciones, lo que debe reservar y lo que sigue sin resolverse. Elige el idioma del destinatario y revisa cualquier texto privado. Marcar una copia como enviada y registrar una confirmación de recepción son acciones separadas."
          }
        ]
      },
      {
        "title": {
          "en": "Requests, shared shops and cook views",
          "es": "Solicitudes, compras compartidas y vistas para quien cocina"
        },
        "paragraphs": [
          {
            "en": "In Settings, open Household requests to sign in. Your private lists and plans stay on this iPhone. You can use them without an account.",
            "es": "Para iniciar sesión, abre Solicitudes del hogar en Configuración. Tus listas y planes privados se guardan en este iPhone. Puedes usarlos sin una cuenta."
          },
          {
            "en": "A request is received only after the household confirms it. If the response is uncertain, retry the same request. A contributor sees their own request and outcome; household budgets stay private.",
            "es": "Una solicitud se considera recibida solo después de que el hogar lo confirme. Si no hay una respuesta segura, reintenta la misma solicitud. Quien colabora ve su propia solicitud y su resultado; los presupuestos del hogar siguen siendo privados."
          },
          {
            "en": "Only the assigned shopper can commit a shared basket change. Another authorized adult can propose a change for review. A membership seat does not grant shopper authority or budget access.",
            "es": "Solo la persona asignada para comprar puede confirmar un cambio en la cesta compartida. Otro adulto autorizado puede proponer un cambio para revisión. Una plaza de membresía no otorga autoridad de compra ni acceso al presupuesto."
          },
          {
            "en": "A current cook view is limited to one shop, selected fields and its expiry. Manage or revoke it through household controls. A dated static message remains a separate copy. Child enrollment requires the configured guardian consent process.",
            "es": "Una vista actual para quien cocina se limita a una compra, los campos seleccionados y su vencimiento. Adminístrala o revócala en los controles del hogar. Un mensaje estático con fecha sigue siendo una copia separada. La inscripción de menores requiere el proceso configurado de consentimiento del tutor."
          }
        ]
      },
      {
        "title": {
          "en": "Export, recover and delete records",
          "es": "Exportar, recuperar y eliminar registros"
        },
        "paragraphs": [
          {
            "en": "In Records, open Recovery, exports and saved records. Choose one source to prepare and preview a readable cook copy. For a readable owner export, select your records and acknowledge the private data before preparing it. For encrypted recovery, save your key separately from the file. Choose where to save or share each copy.",
            "es": "En Historial, abre Recuperación, exportaciones y registros guardados. Elige una fuente para preparar y revisar una copia legible para quien cocina. Para una exportación legible del propietario, selecciona los registros y confirma que entiendes que incluye datos privados antes de prepararla. Para la recuperación cifrada, guarda la clave por separado del archivo. Elige dónde guardar o compartir cada copia."
          },
          {
            "en": "To recover a file, review its source, date, identity, revision and conflicts before importing. A recovery copy opens separately from newer work. A malformed or unsupported file must not replace your saved records.",
            "es": "Para recuperar un archivo, revisa su origen, fecha, identidad, revisión y conflictos antes de importarlo. Una copia de recuperación se abre por separado del trabajo más reciente. Un archivo dañado o no compatible no debe reemplazar tus registros guardados."
          },
          {
            "en": "Deletion names its scope before confirmation. Deleting one record, recovered copies or the entire local ledger has different effects. Use undo only when it is offered. Account deletion is a separate household control; copies already exported or sent remain with their recipients.",
            "es": "La eliminación indica su alcance antes de confirmarla. Eliminar un registro, copias recuperadas o todo el registro local tiene efectos diferentes. Usa Deshacer solo cuando se ofrezca. La eliminación de la cuenta es un control separado del hogar; las copias ya exportadas o enviadas permanecen con sus destinatarios."
          }
        ]
      },
      {
        "title": {
          "en": "Capture, reminders and device shortcuts",
          "es": "Captura, recordatorios y accesos del dispositivo"
        },
        "paragraphs": [
          {
            "en": "Typed entry is always available. Camera, photo, barcode and speech capture create an editable preview. Review names, units, matches and amounts before saving; recognition is not a confirmed fact.",
            "es": "Siempre puedes escribir los datos. La captura con cámara, fotos, códigos de barras y voz crea una vista previa editable. Revisa los nombres, unidades, coincidencias y cantidades antes de guardar; el reconocimiento no es un dato confirmado."
          },
          {
            "en": "Device shortcuts in Settings contains optional share, widget and reminder tools. Review incoming shared text before adding it. Widgets use a narrow view and hide private notes and money.",
            "es": "Accesos del dispositivo en Configuración contiene herramientas opcionales para compartir, widgets y recordatorios. Revisa el texto compartido recibido antes de agregarlo. Los widgets usan una vista limitada y ocultan las notas privadas y el dinero."
          },
          {
            "en": "Choose a specific reminder before allowing notifications. Check local time, quiet hours and expiry. Local reminders do not guarantee live household status while this iPhone is offline.",
            "es": "Elige un recordatorio específico antes de permitir las notificaciones. Revisa la hora local, las horas de silencio y el vencimiento. Los recordatorios locales no garantizan el estado del hogar en tiempo real cuando este iPhone no tiene conexión."
          }
        ]
      },
      {
        "title": {
          "en": "Free tools and Household membership",
          "es": "Herramientas gratuitas y membresía del hogar"
        },
        "paragraphs": [
          {
            "en": "Free covers an ordinary pickup, manual planning, one reusable dinner, saved records and exports. Household adds repeated planning tools for up to two named adults. Groceries are purchased from your retailer.",
            "es": "El plan gratuito cubre una recogida habitual, la planificación manual, una cena reutilizable, los registros guardados y las exportaciones. Household agrega herramientas de planificación recurrente para hasta dos adultos designados. Los comestibles se compran en tu tienda."
          },
          {
            "en": "In Settings, open Household membership to see the App Store price and renewal period, restore a purchase or manage your subscription. You can keep planning for free.",
            "es": "En Configuración, abre Membresía del hogar para ver el precio del App Store y cada cuánto se renueva la suscripción, restaurar una compra o administrar tu suscripción. Puedes seguir planeando gratis."
          },
          {
            "en": "Restore with the original purchasing account and household. A pending or unverified purchase adds no paid access. If delivery is uncertain, retry delivery or restore rather than buying again. Ending membership preserves permitted Free work.",
            "es": "Restaura con la cuenta compradora y el hogar originales. Una compra pendiente o sin verificar no agrega acceso de pago. Si no se confirma la entrega, reintenta la entrega o restaura la compra en vez de comprar otra vez. Al terminar la membresía se conserva el trabajo gratuito permitido."
          }
        ]
      },
      {
        "title": {
          "en": "Track food in Pantry",
          "es": "Llevar la cuenta de los alimentos en la despensa"
        },
        "paragraphs": [
          {
            "en": "On your iPhone, open Pantry to see the food you have and where you keep it. Add food by hand or review lines from a receipt. Check each amount before saving your pantry changes.",
            "es": "En tu iPhone, abre Despensa para ver qué alimentos tienes y dónde los guardas. Agrega alimentos a mano o revisa los renglones de un recibo. Comprueba cada cantidad antes de guardar los cambios en la despensa."
          },
          {
            "en": "You can choose a date to check food quality or look up the food in the offline storage guide. A reminder asks you to open My Pantry to review the food.",
            "es": "Puedes elegir una fecha para revisar la calidad del alimento o consultarlo en la guía de almacenamiento sin conexión. Un recordatorio te pide que abras Mi despensa para revisar el alimento."
          }
        ]
      },
      {
        "id": "child-permission",
        "title": {
          "en": "Children and guardian permission",
          "es": "Menores y permiso del tutor"
        },
        "paragraphs": [
          {
            "en": "With guardian approval and a linked device, your child can ask for a grocery item and see what happened to their own requests. The assigned shopper decides what goes in the basket. Your household budget stays private.",
            "es": "Con el permiso del tutor y un dispositivo vinculado, tu menor puede pedir un producto y ver qué pasó con sus propias solicitudes. Quien se encarga de la compra decide qué va en la cesta. El presupuesto del hogar sigue siendo privado."
          },
          {
            "en": "On the guardian’s iPhone, open Settings, then Household requests. Select your household and open Guardian controls when enabled for your household. The guardian verifies their age, gives permission and confirms the child’s device. If setup is unavailable, you can keep using your private shopping list.",
            "es": "En el iPhone del tutor, abre Configuración y después Solicitudes del hogar. Elige tu hogar y abre Controles del tutor si están habilitados para tu hogar. El tutor verifica su edad, da permiso y confirma el dispositivo del menor. Si la configuración no está disponible, puedes seguir usando tu lista de compras privada."
          }
        ]
      }
    ]
  },
  "privacy": {
    "title": {
      "en": "Privacy and data",
      "es": "Privacidad y datos"
    },
    "lead": {
      "en": "Implementation disclosures · updated November 20, 2026.",
      "es": "Información de la implementación · actualizada el 20 de noviembre de 2026."
    },
    "notice": {
      "en": "Operator policy review and production retention details are still pending. This implementation guide is not a complete operator-approved release privacy policy. The Support page has the supplied support email address.",
      "es": "La revisión de la política por el operador y los detalles de retención en producción siguen pendientes. Esta guía de la implementación no es una política de privacidad de lanzamiento completa y aprobada por el operador. La página de Soporte tiene la dirección de correo de soporte proporcionada."
    },
    "sections": [
      {
        "title": {
          "en": "Your private workspace",
          "es": "Tu espacio privado"
        },
        "paragraphs": [
          {
            "en": "Private comparisons, lists, dinners, capture reviews and pickup records are stored on this iPhone. Joining a household does not upload that existing work. An owner export can include private content and recipient history.",
            "es": "Las comparaciones privadas, listas, cenas, revisiones de captura y registros de recogida se guardan en este iPhone. Unirte a un hogar no sube ese trabajo existente. Una exportación para el propietario puede incluir contenido privado e historial de destinatarios."
          },
          {
            "en": "Local records remain until you change or delete their scope. Recovery files and messages you save or share are separate copies. This source inventory does not establish provider backup retention or a production retention period.",
            "es": "Los registros locales permanecen hasta que cambies o elimines su alcance. Los archivos de recuperación y mensajes que guardas o compartes son copias separadas. Este inventario del código no establece la retención de copias de seguridad de proveedores ni un plazo de retención en producción."
          },
          {
            "en": "If Apple requires an age range and the regional check is enabled, the app asks whether you’ll share it. The app uses the response on this iPhone to decide whether to open your workspace. It keeps the check result in memory and sends no age range to your household.",
            "es": "Si Apple requiere un rango de edad y la comprobación regional está activada, la app te pregunta si quieres compartirlo. La app usa la respuesta en este iPhone para decidir si abre tu espacio de trabajo. Mantiene el resultado de la comprobación en memoria y no envía el rango de edad a tu hogar."
          },
          {
            "en": "You can search the USDA FoodKeeper guide offline. In My Pantry, you can save a date to check food quality and choose a daily reminder. The reminder can appear on your Lock Screen. It asks you to open My Pantry and omits food names.",
            "es": "Puedes consultar la guía FoodKeeper del USDA sin conexión. En Mi despensa puedes guardar una fecha para revisar la calidad de un alimento y activar un recordatorio diario. El recordatorio puede aparecer en la pantalla bloqueada. Te pide que abras Mi despensa y omite los nombres de los alimentos."
          }
        ]
      },
      {
        "title": {
          "en": "Connected information",
          "es": "Información conectada"
        },
        "paragraphs": [
          {
            "en": "Optional connected features use the information needed for the action you review: account email and identity, member aliases, enrolled device/session identifiers, household requests and instructions, shared-shop budget and price evidence, and Apple membership transaction evidence. Permissions limit what each person can read or change.",
            "es": "Las funciones conectadas opcionales usan la información necesaria para la acción que revisas: correo e identidad de la cuenta, alias de miembros, identificadores de dispositivo o sesión inscritos, solicitudes e instrucciones del hogar, presupuesto y pruebas de precios de compras compartidas, y pruebas de transacciones de membresía de Apple. Los permisos limitan lo que cada persona puede leer o cambiar."
          },
          {
            "en": "If you report household content, the service records your reason, which item and version you reported, your member ID and the sender’s ID when known. You can submit the report without sharing the wording, or choose up to 1,000 characters for the review team to read. Reports expire after the period the operator sets for review. Blocking a sender in your household sends no message text.",
            "es": "Si reportas contenido del hogar, el servicio guarda el motivo, qué elemento y versión reportaste, tu identificador de miembro y el de quien lo envió, si se conoce. Puedes enviar el reporte sin compartir el texto o elegir hasta 1,000 caracteres para que los lea el equipo de revisión. Los reportes vencen al terminar el plazo de revisión que establece el operador. Al bloquear en tu hogar a quien lo envió, no se comparte el texto del mensaje."
          },
          {
            "en": "If last calls are available, the shopper can set a cutoff that eligible adults see in the app. The service records your response and whether you mute the invitation. Requests after the cutoff go to the next trip.",
            "es": "Si están disponibles los avisos antes de la compra, quien hace la compra puede fijar una hora límite que las personas adultas con permiso ven en la app. El servicio registra tu respuesta y si silencias el aviso. Las solicitudes posteriores a la hora límite pasan a la siguiente compra."
          },
          {
            "en": "If you request a private review of your authority to delete a child’s account, the service uses the details you provide to verify your request. It keeps a case number, account or enrollment references, status and dates. You can check the case and its expiry in Guardian controls. A separate deletion receipt confirms when the account has been erased.",
            "es": "Si solicitas una revisión privada para verificar que tienes autoridad para eliminar la cuenta de un menor, el servicio usa los datos que proporcionas para verificar la solicitud. Guarda un número de caso, referencias de la cuenta o de la inscripción, el estado y las fechas. En los controles del tutor puedes consultar el caso y su fecha de vencimiento. Un comprobante de eliminación por separado confirma cuándo se eliminó la cuenta."
          },
          {
            "en": "The household service saves a shopper’s question with the contributor’s request. When you save shared instructions for a cook, it stores the wording and your member ID. If you mark the instructions as sent, it also saves the recipient you entered and the time.",
            "es": "El servicio del hogar guarda la pregunta de quien hace la compra junto con la solicitud de quien la envió. Cuando guardas instrucciones compartidas para quien cocina, el servicio guarda el texto y tu identificador de miembro. Si marcas las instrucciones como enviadas, también guarda el destinatario que indicaste y la hora."
          },
          {
            "en": "Saving a draft during line review keeps all recognized receipt text, including unselected lines, in protected storage on this iPhone. Saving at put-away keeps your selected details and choices. Finish or discard the draft to remove it. To view the original photo or PDF again, select it from its source.",
            "es": "Si guardas un borrador al revisar los renglones, todo el texto reconocido del recibo, incluidos los renglones sin seleccionar, se guarda en el almacenamiento protegido de este iPhone. Si lo guardas al registrar los alimentos, se conservan los datos y las opciones que seleccionaste. El borrador se elimina cuando terminas o lo descartas. Para volver a ver la foto o el PDF original, selecciónalo desde su origen."
          },
          {
            "en": "When you confirm a receipt for the household pantry, adults with pantry access can see the store, purchase date, any reference you enter, and each selected line’s original wording, food, quantities, storage location and price if entered. The original file stays on this iPhone.",
            "es": "Al confirmar un recibo para la despensa del hogar, los adultos con acceso a la despensa pueden ver la tienda, la fecha de compra, la referencia que ingreses y, de cada renglón seleccionado, el texto original, el alimento, las cantidades, el lugar de almacenamiento y el precio si lo ingresaste. El archivo original se queda en este iPhone."
          },
          {
            "en": "When you choose Read recipe for a web link, this iPhone requests the page directly from the recipe website. The site sees the page address you requested, including any query parameters, your IP address and an identifier for the app’s recipe reader. A site the link redirects you to receives the same kinds of information.",
            "es": "Cuando eliges Leer receta para un enlace web, este iPhone solicita la página directamente al sitio de la receta. El sitio ve la dirección que solicitaste, incluidos los parámetros de consulta, tu dirección IP y un identificador del lector de recetas de la app. Si el enlace te dirige a otro sitio, ese sitio recibe el mismo tipo de información."
          },
          {
            "en": "When you save a recipe in Household Tonight, you send its ingredients, portions, selected pantry batches and any reviewed restrictions or package details to the household service. Adults with pantry access can see the recipe title and ingredients when the meal appears as a suggestion.",
            "es": "Cuando guardas una receta en «Esta noche en casa», envías al servicio del hogar los ingredientes, las porciones, los lotes que elegiste y las restricciones o los datos del paquete que hayas revisado. Los adultos con acceso a la despensa pueden ver el nombre de la receta y sus ingredientes cuando se les sugiere esa cena."
          },
          {
            "en": "When you share a reaction to a meal you shopped for, the household service saves it with your member ID. For up to 90 days, Household Tonight can use your latest reaction to that version of the recipe to break ties between dinner suggestions for you. To withdraw your reactions, open Household pantry and choose Review my shared meal feedback.",
            "es": "Cuando compartes tu opinión sobre una comida para la que hiciste la compra, el servicio del hogar la guarda con tu identificador de miembro. Durante un máximo de 90 días, «Esta noche en casa» puede usar tu opinión más reciente sobre esa versión de la receta para decidir qué cena mostrarte primero si hay un empate. Para retirar tus opiniones, abre «Despensa del hogar» y elige «Revisar mis opiniones compartidas sobre comidas»."
          },
          {
            "en": "If the household receipt save is unconfirmed, this iPhone keeps a protected copy of the reviewed details. Check the household pantry before retrying the same change. Clearing the retry leaves any receipt the household already saved in place.",
            "es": "Si no se confirma que se guardó el recibo del hogar, este iPhone conserva una copia protegida de los datos revisados. Comprueba la despensa del hogar antes de reintentar el mismo cambio. Borrar el reintento conserva cualquier recibo ya guardado en el hogar."
          },
          {
            "en": "The implemented service uses Supabase for identity and PostgreSQL storage, Vercel for staging hosting, and Apple for subscription payment and verification. The app does not receive payment card or bank account numbers. Final provider settings and production retention require operator review.",
            "es": "El servicio implementado usa Supabase para identidad y almacenamiento PostgreSQL, Vercel para alojamiento de pruebas y Apple para pagos y verificación de suscripciones. La app no recibe números de tarjetas de pago ni de cuentas bancarias. La configuración final de proveedores y la retención en producción requieren revisión del operador."
          },
          {
            "en": "If Apple tells Room in the Cart that a guardian withdrew permission for an App Store download, the service saves a receipt to recognize repeated notices. The receipt contains the notice ID, the time Apple signed it and whether it came from the live or test App Store. It contains no age range, download ID or household account.",
            "es": "Si Apple avisa a Room in the Cart de que un tutor retiró el permiso para descargar la app del App Store, el servicio guarda un comprobante para reconocer los avisos repetidos. El comprobante contiene el identificador del aviso, la hora en que Apple lo firmó y si procede del App Store o de su entorno de pruebas. No contiene el rango de edad ni identifica la descarga o la cuenta del hogar."
          },
          {
            "en": "A cook link exposes only its granted fields. A static message or exported file is a separate copy under the recipient’s control. Review the destination and private fields before sharing.",
            "es": "Un enlace para quien cocina muestra solo los campos autorizados. Un mensaje estático o un archivo exportado es una copia separada bajo el control del destinatario. Revisa el destino y los campos privados antes de compartir."
          }
        ]
      },
      {
        "title": {
          "en": "Photos and speech",
          "es": "Fotos y voz"
        },
        "paragraphs": [
          {
            "en": "Ordinary dictation and photo text recognition run on this iPhone. Saved evidence photos stay in protected local storage. Readable and helper exports exclude photos. An encrypted recovery file can include evidence photos only after you select and review them. Apple may download a selected iCloud photo.",
            "es": "El dictado habitual y el reconocimiento de texto en fotos se procesan en este iPhone. Las fotos guardadas como evidencia permanecen en el almacenamiento local protegido. Las exportaciones legibles y para ayudantes excluyen las fotos. Un archivo de recuperación cifrado puede incluirlas si las seleccionas y revisas. Apple puede descargar de iCloud una foto que elijas."
          },
          {
            "en": "If product references are available, an adult can choose to share a description, brand, size or barcode with the named shopper. When photo sharing is enabled separately, the service receives only the crop you review, without location metadata. An authorized moderator reviews it before the shopper can see it. You can remove a shared reference. Access expires within seven days.",
            "es": "Si están disponibles las referencias de productos, una persona adulta puede compartir una descripción, marca, tamaño o código de barras con la persona indicada para hacer la compra. Si además se habilita el uso de fotos, el servicio recibe solo el recorte que revises, sin metadatos de ubicación. Una persona autorizada lo revisa antes de que lo vea quien hace la compra. Puedes retirar una referencia compartida. El acceso caduca en un máximo de siete días."
          },
          {
            "en": "When online assistance is available, an authorized adult can review and send a selected excerpt, a cropped image or a separate voice recording to OpenAI through Room in the Cart. Listen to the recording or inspect the crop before sending. You can keep using the local editor.",
            "es": "Cuando la asistencia en línea está disponible, un adulto autorizado puede revisar y enviar un fragmento de texto, una imagen recortada o una grabación de voz independiente a OpenAI a través de Room in the Cart. Escucha la grabación o revisa el recorte antes de enviarlo. También puedes seguir usando el editor local."
          },
          {
            "en": "The household service counts online assistance requests for your account to enforce the daily limit. It also keeps a code for each request to prevent processing it twice. The service can remove these records once they are more than 24 hours old.",
            "es": "El servicio del hogar cuenta las solicitudes de asistencia en línea de tu cuenta para aplicar el límite diario. También guarda un código por solicitud para evitar procesarla dos veces. El servicio puede eliminar estos registros una vez que hayan pasado 24 horas."
          },
          {
            "en": "Looking up a barcode in Open Food Facts sends the barcode, app version and the app’s support email to that service. It also sees your IP address. Its privacy policy says it keeps visitor IP addresses and logs for three years for security, technical analysis and measuring popularity. You can enter the product name and package size yourself.",
            "es": "Si consultas un código de barras en Open Food Facts, se envían a ese servicio el código, la versión de la app y el correo de soporte de la app. El servicio también ve tu dirección IP. Según su política de privacidad, conserva las direcciones IP de los visitantes y los registros de visitas durante tres años por motivos de seguridad, para realizar análisis técnicos y para medir la popularidad. Puedes ingresar el nombre del producto y el tamaño del paquete manualmente."
          },
          {
            "en": "For optional online language help, review what will go to OpenAI through Room in the Cart. Depending on the task, this can include your wording, possible matches, or selected meal titles and reasons. For a FoodKeeper match, you share the label wording and the names and IDs of the guide entries shown. You choose whether to use a suggestion.",
            "es": "Para usar la ayuda de redacción o de coincidencias en línea, revisa qué se enviará a OpenAI a través de Room in the Cart. Según la tarea, puede incluir tu texto, posibles coincidencias o los títulos y motivos de las comidas seleccionadas. Para buscar una coincidencia en FoodKeeper, compartes el texto de la etiqueta y los nombres e identificadores de las entradas que se muestran. Tú decides si usas la sugerencia."
          }
        ]
      },
      {
        "title": {
          "en": "Optional feedback and measurement",
          "es": "Comentarios y medición opcionales"
        },
        "paragraphs": [
          {
            "en": "Optional pickup feedback stays in your local pickup record. It is not sent to an analytics service. You can turn the prompt off in Settings and remove a saved response from its pickup.",
            "es": "Los comentarios opcionales sobre una recogida permanecen en su registro local. No se envían a un servicio de análisis. Puedes desactivar la pregunta en Configuración y quitar una respuesta guardada desde su recogida."
          },
          {
            "en": "Optional household measurement is separate. With explicit consent, the service stores the response codes you review, the shop identity, eligible week and notice version, and can match membership status to study retention. Existing local feedback, grocery text, prices and member names are not sent. Manage or withdraw that consent in Settings.",
            "es": "La medición opcional del hogar es independiente. Con consentimiento explícito, el servicio guarda los códigos de respuesta que revises, la identidad de la compra, la semana elegible y la versión del aviso, y puede vincular el estado de membresía para estudiar la retención. No se envían los comentarios locales existentes, el texto de comestibles, los precios ni los nombres de miembros. Administra o retira ese consentimiento en Configuración."
          }
        ]
      },
      {
        "title": {
          "en": "Browser storage and tracking",
          "es": "Almacenamiento del navegador y rastreo"
        },
        "paragraphs": [
          {
            "en": "These public information pages do not sign you in, call the household API, use cookies or local storage, or add analytics. The invited app uses a same-origin authenticated session. Its local request queue requires enrollment, service permission and separate explicit consent; queued is not received. Invitation secrets are removed from the address before the invited app makes requests.",
            "es": "Estas páginas de información pública no inician sesión, no llaman a la API del hogar, no usan cookies ni almacenamiento local, y no agregan análisis. La app por invitación usa una sesión autenticada del mismo origen. Su cola local de solicitudes requiere inscripción, permiso del servicio y consentimiento explícito separado; en cola no significa recibida. Los secretos de invitación se quitan de la dirección antes de que la app por invitación haga solicitudes."
          },
          {
            "en": "The native privacy manifest declares no tracking. The implementation does not add advertising identifiers or cross-site analytics. Hosting and identity providers still handle the technical information needed to serve and protect their services; their final operational settings need release review.",
            "es": "El manifiesto de privacidad nativo declara que no hay rastreo. La implementación no agrega identificadores publicitarios ni análisis entre sitios. Los proveedores de alojamiento e identidad aún procesan la información técnica necesaria para prestar y proteger sus servicios; su configuración operativa final necesita revisión antes del lanzamiento."
          }
        ]
      },
      {
        "title": {
          "en": "Export and deletion",
          "es": "Exportación y eliminación"
        },
        "paragraphs": [
          {
            "en": "Open Records, then Recovery, exports and saved records to preview an export, recover a file or review local deletion. Removing local work does not remove copies you already saved or sent.",
            "es": "Abre Historial y luego Recuperación, exportaciones y registros guardados para revisar una exportación, recuperar un archivo o revisar una eliminación local. Quitar trabajo local no elimina las copias que ya guardaste o enviaste."
          },
          {
            "en": "Household account deletion has its own scope and status. Review it in household controls. Signing out or leaving a household is separate from deleting an account, and deleting an account does not cancel an Apple subscription. Manage that subscription through Apple.",
            "es": "La eliminación de una cuenta del hogar tiene su propio alcance y estado. Revísala en los controles del hogar. Cerrar sesión o salir de un hogar es distinto de eliminar una cuenta, y eliminar una cuenta no cancela una suscripción de Apple. Administra esa suscripción con Apple."
          },
          {
            "en": "Deleting your account erases the household receipt lines you submitted. To prevent the same lines from being imported again, the service keeps receipt identification codes and the positions of the erased lines. These records omit the printed wording.",
            "es": "Al eliminar tu cuenta se borran los renglones de recibos que enviaste para el hogar. Para evitar que vuelvan a importarse, el servicio conserva códigos que identifican el recibo y las posiciones de los renglones borrados. Estos registros omiten el texto impreso."
          },
          {
            "en": "An accepted deletion request and completed provider deletion are different states. Follow the in-app status and retry instructions. The operating owner must verify provider erasure, backups and retention before release. Child enrollment remains unavailable until a real guardian verification and consent process is configured.",
            "es": "Una solicitud de eliminación aceptada y la eliminación completada por el proveedor son estados distintos. Sigue el estado y las instrucciones de reintento de la app. El operador debe verificar el borrado del proveedor, las copias de seguridad y la retención antes del lanzamiento. La inscripción de menores sigue sin estar disponible hasta configurar un proceso real de verificación del tutor y consentimiento."
          }
        ]
      },
      {
        "title": {
          "en": "Support information",
          "es": "Información de soporte"
        },
        "paragraphs": [
          {
            "en": "When Resend delivers a sign-in code, it processes the recipient’s email address and the message containing the code. If you email support, Cloudflare Email Routing forwards your address, message and any attachments to the operator’s Gmail inbox so the operator can respond.",
            "es": "Cuando Resend entrega un código de inicio de sesión, procesa la dirección de correo del destinatario y el mensaje que contiene el código. Si escribes a soporte, Cloudflare Email Routing reenvía tu dirección, el mensaje y los archivos que adjuntes al buzón de Gmail del operador para que pueda responderte."
          },
          {
            "en": "The native Support screen previews a summary containing only app version/build, iOS version, interface language, build environment and configuration-presence booleans. Nothing is sent automatically. Support does not need a private recovery file by default.",
            "es": "La pantalla de Soporte nativa muestra un resumen que contiene solo la versión y compilación de la app, la versión de iOS, el idioma de la interfaz, el entorno de compilación y valores que indican si existe configuración. No se envía nada automáticamente. Soporte no necesita un archivo privado de recuperación de forma predeterminada."
          }
        ]
      }
    ]
  },
  "terms": {
    "title": {
      "en": "Terms of use",
      "es": "Términos de uso"
    },
    "lead": {
      "en": "Product and purchase information for the current implementation.",
      "es": "Información del producto y las compras para la implementación actual."
    },
    "notice": {
      "en": "Operator-approved release terms are pending. The information below describes supported behavior and does not replace those final terms.",
      "es": "Los términos de lanzamiento aprobados por el operador siguen pendientes. La información siguiente describe el comportamiento compatible y no reemplaza los términos finales."
    },
    "sections": [
      {
        "title": {
          "en": "What the app does",
          "es": "Qué hace la app"
        },
        "paragraphs": [
          {
            "en": "Room in the Cart helps people compare usable grocery packs, plan meals, review household requests and record a pickup. Entered prices, quantities, availability, credits and outcomes remain the person’s reports. Review uncertain or changed information before acting.",
            "es": "Room in the Cart ayuda a comparar paquetes aprovechables de comestibles, planificar comidas, revisar solicitudes del hogar y registrar una recogida. Los precios, cantidades, disponibilidad, créditos y resultados ingresados siguen siendo datos reportados por la persona. Revisa la información incierta o que haya cambiado antes de actuar."
          },
          {
            "en": "The app does not operate a grocery marketplace, place retailer orders, provide live inventory, guarantee savings, certify allergy suitability, or provide medical or nutrition advice. You place and pay for groceries through your retailer.",
            "es": "La app no opera un mercado de comestibles, no realiza pedidos en tiendas, no ofrece inventario en tiempo real, no garantiza ahorros, no certifica la idoneidad para alergias ni ofrece asesoría médica o nutricional. Tú realizas y pagas las compras en tu tienda."
          }
        ]
      },
      {
        "title": {
          "en": "Shared access",
          "es": "Acceso compartido"
        },
        "paragraphs": [
          {
            "en": "Only the assigned shopper can commit a shared basket change. Another authorized adult can propose a change for review. A membership seat does not grant shopper authority or budget access.",
            "es": "Solo la persona asignada para comprar puede confirmar un cambio en la cesta compartida. Otro adulto autorizado puede proponer un cambio para revisión. Una plaza de membresía no otorga autoridad de compra ni acceso al presupuesto."
          },
          {
            "en": "Invitations and cook views have a specific household, role, shop and scope. Do not share account credentials or invitation secrets. Review selected fields and expiry before issuing a current view. Copies already sent or exported remain separate.",
            "es": "Las invitaciones y vistas para quien cocina tienen un hogar, rol, compra y alcance específicos. No compartas credenciales de cuenta ni secretos de invitación. Revisa los campos seleccionados y el vencimiento antes de emitir una vista actual. Las copias ya enviadas o exportadas siguen siendo independientes."
          }
        ]
      },
      {
        "title": {
          "en": "Free tools and Household membership",
          "es": "Herramientas gratuitas y membresía del hogar"
        },
        "paragraphs": [
          {
            "en": "Free covers an ordinary pickup, manual planning, one reusable dinner, saved records and exports. Household adds repeated planning tools for up to two named adults. Groceries are purchased from your retailer.",
            "es": "El plan gratuito cubre una recogida habitual, la planificación manual, una cena reutilizable, los registros guardados y las exportaciones. Household agrega herramientas de planificación recurrente para hasta dos adultos designados. Los comestibles se compran en tu tienda."
          },
          {
            "en": "The native membership screen shows Apple’s actual localized product and subscription period when configured and available. Payment is charged to the Apple Account. The subscription renews automatically unless canceled at least 24 hours before the current period ends. Use Restore Purchases and Manage Subscription in the app. No local example price is a live offer.",
            "es": "La pantalla de membresía nativa muestra el producto localizado real de Apple y el período de suscripción cuando está configurado y disponible. El pago se carga a la cuenta de Apple. La suscripción se renueva automáticamente salvo que se cancele al menos 24 horas antes de finalizar el período actual. Usa Restaurar compras y Administrar suscripción en la app. Ningún precio de ejemplo local es una oferta vigente."
          },
          {
            "en": "Restore with the original purchasing account and household. A pending or unverified purchase adds no paid access. If delivery is uncertain, retry delivery or restore rather than buying again. Ending membership preserves permitted Free work.",
            "es": "Restaura con la cuenta compradora y el hogar originales. Una compra pendiente o sin verificar no agrega acceso de pago. Si no se confirma la entrega, reintenta la entrega o restaura la compra en vez de comprar otra vez. Al terminar la membresía se conserva el trabajo gratuito permitido."
          }
        ]
      },
      {
        "title": {
          "en": "Data controls",
          "es": "Controles de datos"
        },
        "paragraphs": [
          {
            "en": "Review sharing, recovery and deletion scopes in the app. Account deletion does not cancel an Apple subscription. Exported files and static messages cannot be recalled from recipients by deleting local records. Read the privacy information and use the in-app controls before sharing private content.",
            "es": "Revisa en la app los alcances de compartir, recuperar y eliminar. Eliminar una cuenta no cancela una suscripción de Apple. Eliminar registros locales no retira los archivos exportados ni los mensajes estáticos de sus destinatarios. Lee la información de privacidad y usa los controles de la app antes de compartir contenido privado."
          }
        ]
      }
    ]
  },
  "support": {
    "title": {
      "en": "Support",
      "es": "Soporte"
    },
    "lead": {
      "en": "Find the next step without sharing private grocery information.",
      "es": "Encuentra el siguiente paso sin compartir información privada de comestibles."
    },
    "notice": {
      "en": "A monitored operator support destination has not been configured. This page does not submit a support request or upload files. Offline native help and the reviewed support summary remain available.",
      "es": "No se ha configurado un destino de soporte supervisado por el operador. Esta página no envía solicitudes de soporte ni sube archivos. La ayuda nativa sin conexión y el resumen de soporte revisado siguen disponibles."
    },
    "sections": [
      {
        "title": {
          "en": "Get help",
          "es": "Obtener ayuda"
        },
        "paragraphs": [
          {
            "en": "Describe the steps, what you expected and what happened. Leave out grocery details, budgets, names, receipts, sign-in codes and invitation links.",
            "es": "Describe los pasos, lo que esperabas y lo que ocurrió. Omite detalles de comestibles, presupuestos, nombres, recibos, códigos de inicio de sesión y enlaces de invitación."
          },
          {
            "en": "In the iPhone app, open Settings, then Support. Review the fixed-field support summary before sharing it. It contains no food, money, account/device identifiers, credentials, logs or photos. Nothing is sent automatically.",
            "es": "En la app para iPhone, abre Configuración y luego Soporte. Revisa el resumen de campos fijos antes de compartirlo. No contiene comida, dinero, identificadores de cuenta o dispositivo, credenciales, registros técnicos ni fotos. No se envía nada automáticamente."
          }
        ]
      },
      {
        "title": {
          "en": "An uncertain save or request",
          "es": "Un guardado o una solicitud sin confirmar"
        },
        "paragraphs": [
          {
            "en": "Keep the current page or draft open. Follow its retry action so the same operation is checked again. A request is received only after the household confirms it. Do not send another copy just because a response was lost.",
            "es": "Mantén abierta la página o el borrador actual. Sigue su acción de reintento para volver a comprobar la misma operación. Una solicitud se recibe solo después de que el hogar lo confirme. No envíes otra copia solo porque se perdió una respuesta."
          }
        ]
      },
      {
        "title": {
          "en": "Recovery and deletion",
          "es": "Recuperación y eliminación"
        },
        "paragraphs": [
          {
            "en": "Use Records to review recovery files and local deletion scope. Do not attach a full personal backup or receipt by default. An account-deletion request has its own status in household controls; do not mistake signing out for erasure.",
            "es": "Usa Historial para revisar archivos de recuperación y el alcance de la eliminación local. No adjuntes una copia personal completa ni un recibo de forma predeterminada. Una solicitud de eliminación de cuenta tiene su propio estado en los controles del hogar; no confundas cerrar sesión con borrar los datos."
          }
        ]
      },
      {
        "title": {
          "en": "Membership help",
          "es": "Ayuda con la membresía"
        },
        "paragraphs": [
          {
            "en": "Use the original purchasing account and household, then Restore Purchases in Settings, Household membership. If the app reports unconfirmed delivery, retry or restore without purchasing again. Manage or cancel through Apple subscriptions.",
            "es": "Usa la cuenta compradora y el hogar originales, y luego Restaurar compras en Configuración, Membresía del hogar. Si la app indica una entrega sin confirmar, reintenta o restaura sin comprar otra vez. Administra o cancela desde las suscripciones de Apple."
          }
        ]
      }
    ]
  }
} satisfies Readonly<Record<PublicPageKey, PublicPage>>;
