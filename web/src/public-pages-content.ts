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
      "en": "The Room in the Cart privacy policy explains what the app collects, how your information is used and how to request deletion.",
      "es": "La política de privacidad de Room in the Cart explica qué datos recopila la app, cómo se usa tu información y cómo solicitar que se elimine."
    },
    "notice": null,
    "sections": []
  },
  "terms": {
    "title": {
      "en": "Terms of use",
      "es": "Términos de uso"
    },
    "lead": {
      "en": "The iPhone app uses Apple’s Standard End User License Agreement.",
      "es": "La app para iPhone utiliza el contrato de licencia estándar de Apple para el usuario final."
    },
    "notice": null,
    "sections": []
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
      "en": "If you cannot open an email app, visit the support website. In the iPhone app you can also read Help in Settings while offline.",
      "es": "Si no puedes abrir una app de correo, visita el sitio de soporte. En la app para iPhone también puedes consultar Ayuda en Configuración sin conexión."
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
