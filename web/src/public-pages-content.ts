// Source-based English and US-Spanish draft copy. Human language, operator
// policy/terms and production retention review remain release requirements.
export type PublicLanguage = 'en' | 'es';
export type PublicPageKey = 'help' | 'privacy' | 'terms' | 'support';
export type PublicCopy = Readonly<Record<PublicLanguage, string>>;
export type PublicPage = Readonly<{ title: PublicCopy; lead: PublicCopy; notice: PublicCopy | null;
  sections: readonly Readonly<{ title: PublicCopy; paragraphs: readonly PublicCopy[] }>[] }>;

export const publicPages = {
  "help": {
    "title": {
      "en": "Help",
      "es": "Ayuda"
    },
    "lead": {
      "en": "You can compare packs and plan a pickup on your iPhone without signing in. Open a household invitation to send a request or read shared instructions in your browser.",
      "es": "Puedes comparar paquetes y planificar una recogida en tu iPhone sin iniciar sesión. Abre una invitación del hogar para enviar una solicitud o leer las instrucciones compartidas en tu navegador."
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
            "en": "This website is for invited contributors and cooks. Open the invitation or current-view link your household gave you. Sign-in, household membership and the selected view are checked separately. If email sign-in or guardian consent is unavailable, the page says so; it does not create access.",
            "es": "Este sitio web es para colaboradores y personas que cocinan con invitación. Abre el enlace de invitación o de vista actual que te dio tu hogar. El inicio de sesión, la pertenencia al hogar y la vista seleccionada se verifican por separado. Si el inicio de sesión por correo o el consentimiento del tutor no está disponible, la página lo indica; no crea acceso."
          },
          {
            "en": "Review a request before sending. Received means the household confirmed it. Waiting to send means it has not been received. Retry an uncertain submission with the original retry action rather than sending a duplicate. A cook with permission can suggest a correction; only the shopper can approve a basket change.",
            "es": "Revisa una solicitud antes de enviarla. Recibida significa que el hogar la confirmó. Pendiente de enviar significa que no se ha recibido. Si un envío no tiene resultado confirmado, usa la acción de reintento original en vez de enviar un duplicado. Quien cocina con permiso puede sugerir una corrección; solo la persona asignada para comprar puede aprobar un cambio en la cesta."
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
            "en": "In Dinner library, open Import and use recipes to type a family recipe or choose a Recipe JSON-LD file from Files. Review and save the recipe. When you want to shop for it, open the saved recipe and review the ingredients for that pickup.",
            "es": "En Biblioteca de cenas, abre Importar y usar recetas para escribir una receta familiar o elegir un archivo Recipe JSON-LD desde Archivos. Revisa y guarda la receta. Cuando quieras comprar los ingredientes, abre la receta guardada y revísalos para esa recogida."
          },
          {
            "en": "Use the meal week for guests, away nights and protected lunches. Preview a change before saving it. Editing this week does not rewrite your reusable dinner or rotation.",
            "es": "Usa la semana de comidas para invitados, noches fuera y almuerzos reservados. Revisa el cambio antes de guardarlo. Editar esta semana no modifica tu cena reutilizable ni tu rotación."
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
            "en": "Open Household requests in Settings to sign in or manage connected access. Signing in does not upload your existing private workspace. If sign-in is unavailable in this build, keep using the private tools.",
            "es": "Abre Solicitudes del hogar en Configuración para iniciar sesión o administrar el acceso conectado. Iniciar sesión no sube tu espacio privado existente. Si esta versión no permite iniciar sesión, sigue usando las herramientas privadas."
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
            "en": "In Records, open Recovery, exports and saved records. Select readable records, then preview a helper copy, a readable owner export or a structured recovery file. Owner files can include private data. Choose where to save or share them.",
            "es": "En Historial, abre Recuperación, exportaciones y registros guardados. Selecciona los registros que se pueden leer y revisa una copia para ayudante, una exportación legible para el propietario o un archivo estructurado de recuperación. Los archivos del propietario pueden incluir datos privados. Elige dónde guardarlos o compartirlos."
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
            "en": "Open Household membership in Settings for Apple’s actual localized offer, Restore Purchases and Manage Subscription. If the offer or account setup is unavailable, continue with Free.",
            "es": "Abre Membresía del hogar en Configuración para ver la oferta localizada real de Apple, Restaurar compras y Administrar suscripción. Si la oferta o la configuración de la cuenta no está disponible, continúa con el plan gratuito."
          },
          {
            "en": "Restore with the original purchasing account and household. A pending or unverified purchase adds no paid access. If delivery is uncertain, retry delivery or restore rather than buying again. Ending membership preserves permitted Free work.",
            "es": "Restaura con la cuenta compradora y el hogar originales. Una compra pendiente o sin verificar no agrega acceso de pago. Si no se confirma la entrega, reintenta la entrega o restaura la compra en vez de comprar otra vez. Al terminar la membresía se conserva el trabajo gratuito permitido."
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
      "en": "Implementation disclosures · updated November 3, 2026.",
      "es": "Información de la implementación · actualizada el 3 de noviembre de 2026."
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
            "en": "The implemented service uses Supabase for identity and PostgreSQL storage, Vercel for staging hosting, and Apple for subscription payment and verification. The app does not receive payment card or bank account numbers. Final provider settings and production retention require operator review.",
            "es": "El servicio implementado usa Supabase para identidad y almacenamiento PostgreSQL, Vercel para alojamiento de pruebas y Apple para pagos y verificación de suscripciones. La app no recibe números de tarjetas de pago ni de cuentas bancarias. La configuración final de proveedores y la retención en producción requieren revisión del operador."
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
            "en": "The app’s capture tools process speech and images on this iPhone. Raw voice recordings are not retained or uploaded by the app. Saved evidence photos stay in protected local storage. Readable and helper exports exclude photos. An encrypted recovery file can include evidence photos only after you select and review them. Apple may download a photo you select from iCloud before delivering it to the app.",
            "es": "Las herramientas de captura de la app procesan la voz y las imágenes en este iPhone. La app no conserva ni sube las grabaciones de voz originales. Las fotos guardadas como evidencia permanecen en almacenamiento local protegido. Las exportaciones legibles y para ayudantes excluyen las fotos. Un archivo de recuperación cifrado puede incluir fotos de evidencia solo después de que las selecciones y revises. Apple puede descargar de iCloud una foto que selecciones antes de entregarla a la app."
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
