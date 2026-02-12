# Moxie CRM Public API Specification

> Auto-generated from [Moxie Help Center](https://help.withmoxie.com/en/collections/5482062-public-api-endpoints) — 29 endpoints total.

---

## Authentication & Base URL

| Item | Details |
|------|---------|
| **Base URL** | `https://{pod}.withmoxie.dev/api/public` (find your pod URL in Workspace Settings → Connected Apps → Integrations) |
| **Auth Header** | `X-API-KEY: <your-api-key>` |
| **Content-Type** | `application/json` (except file upload endpoints which use `multipart/form-data`) |
| **Rate Limit** | 100 requests per 5-minute window (HTTP 429 on exceed) |
| **Setup** | Enable via Workspace Settings → Connected Apps → Integrations → "Enable Custom Integration" |

All endpoint paths below are relative to the Base URL. E.g., `/action/clients/list` → `https://pod00.withmoxie.dev/api/public/action/clients/list`

---

## Summary Table

| # | Endpoint | Method | Path | Description |
|---|----------|--------|------|-------------|
| **Read / List / Search** | | | | |
| 1 | List Clients | GET | `/action/clients/list` | List all clients |
| 2 | Search Clients | GET | `/action/clients/search?query=` | Search by name or contact info |
| 3 | Search Contacts | GET | `/action/contacts/search?query=` | Search contacts by name/email |
| 4 | Search Projects | GET | `/action/projects/search?query=` | Search active projects |
| 5 | Search Payable Invoices | GET | `/action/payableInvoices/search?query=` | Find invoices in payable state |
| 6 | List Email Templates | GET | `/action/emailTemplates/list` | List email template names |
| 7 | List Invoice Templates | GET | `/action/invoiceTemplates/list` | List invoice template names |
| 8 | List Vendor Names | GET | `/action/vendors/list` | List all vendor names |
| 9 | List Form Names | GET | `/action/formNames/list` | List form template names |
| 10 | List Pipeline Stages | GET | `/action/pipelineStages/list` | List sales pipeline stages |
| 11 | List Project Task Stages | GET | `/action/taskStages/list` | List project task kanban stages |
| 12 | List Workspace Users | GET | `/action/users/list` | List users and permissions |
| **Create** | | | | |
| 13 | Create Client | POST | `/action/clients/create` | Create a new client |
| 14 | Create Contact | POST | `/action/contacts/create` | Create a contact |
| 15 | Create Invoice | POST | `/action/invoices/create` | Create an invoice with line items |
| 16 | Create Expense | POST | `/action/expenses/create` | Create an expense record |
| 17 | Create Form Submission | POST | `/action/formSubmissions/create` | Create a form submission |
| 18 | Create Project | POST | `/action/projects/create` | Create a new project |
| 19 | Create Task | POST | `/action/tasks/create` | Create a task in project management |
| 20 | Create Ticket | POST | `/action/tickets/create` | Create a support ticket |
| 21 | Create Comment on Ticket | POST | `/action/tickets/comments/create` | Add comment to ticket |
| 22 | Create Opportunity | POST | `/action/opportunities/create` | Create pipeline opportunity |
| 23 | Create Time Entry | POST | `/action/timeWorked/create` | Create a timesheet entry |
| **Actions** | | | | |
| 24 | Approve Deliverable | POST | `/action/deliverable/approve` | Approve a client-workflow deliverable |
| 25 | Apply Payment to Invoice | POST | `/action/payment/create` | Apply payment to open invoice |
| 26 | Attach File (Multipart) | POST | `/action/attachments/create` | Upload file attachment (multipart) |
| 27 | Attach File (from URL) | POST | `/action/attachments/createFromUrl` | Attach file from URL |
| 28 | Create/Update Calendar Event | POST | `/action/calendar/createOrUpdate` | Upsert calendar event |
| 29 | Delete Calendar Event | DELETE | `/action/calendar/{eventId}` | Delete calendar event by external ID |

---

## Read / List / Search Endpoints

### 1. List Clients

- **Method:** `GET`
- **Path:** `/action/clients/list`
- **Parameters:** None
- **Response:** Array of client objects

```json
[
  {
    "name": "",
    "clientType": "Client",
    "initials": "",
    "address1": "",
    "address2": "",
    "city": "",
    "locality": "",
    "postal": "",
    "country": "",
    "website": "",
    "phone": "",
    "color": "",
    "taxId": "",
    "leadSource": "",
    "archive": false,
    "paymentTerms": {
      "paymentDays": 0,
      "latePaymentFee": 0.00,
      "hourlyAmount": 0.00,
      "whoPaysCardFees": "Client"
    },
    "payInstructions": "",
    "hourlyAmount": 0.00,
    "roundingIncrement": 0,
    "currency": "USD",
    "stripeClientId": "",
    "notes": "",
    "contacts": [
      {
        "firstName": "",
        "lastName": "",
        "role": "",
        "phone": "",
        "email": "",
        "notes": "",
        "defaultContact": false,
        "invoiceContact": false,
        "portalAccess": false
      }
    ]
  }
]
```

---

### 2. Search Clients

- **Method:** `GET`
- **Path:** `/action/clients/search?query=`
- **Parameters:**
  - `query` (required) — client name starts with, contact email starts with, or contact full name contains
- **Response:** Same structure as List Clients. Empty array if no results.

---

### 3. Search Contacts

- **Method:** `GET`
- **Path:** `/action/contacts/search?query=`
- **Parameters:**
  - `query` (optional) — matches first name, last name, or email
- **Response:** Array of contact objects

```json
[
  {
    "id": "",
    "accountId": 0,
    "clientId": "",
    "clientPortalUserId": 0,
    "firstName": "",
    "lastName": "",
    "role": "",
    "phone": "",
    "email": "",
    "mobile": "",
    "notes": "",
    "defaultContact": false,
    "invoiceContact": false,
    "portalAccess": false,
    "importRecordId": "",
    "sampleData": false
  }
]
```

---

### 4. Search Projects

- **Method:** `GET`
- **Path:** `/action/projects/search?query=`
- **Parameters:**
  - `query` (optional) — client name filter for specific client's projects
- **Response:** Array of project objects (includes nested `client` and `feeSchedule`)

```json
[
  {
    "id": "",
    "accountId": 0,
    "sampleData": false,
    "clientId": "",
    "name": "",
    "description": "",
    "active": false,
    "startDate": "2023-08-15",
    "dueDate": "2023-08-15",
    "dateCreated": "2023-08-15T07:34:25.36-04:00",
    "client": {
      "accountId": 0,
      "sampleData": false,
      "id": "",
      "clientType": "Client",
      "name": "",
      "initials": "",
      "locality": "",
      "country": "",
      "color": "",
      "hourlyAmount": 0,
      "archive": false,
      "currency": "",
      "logo": "",
      "leadSource": "",
      "contact": { "..." : "..." }
    },
    "leadGenArchived": false,
    "feeSchedule": {
      "feeType": "HOURLY",
      "amount": 0,
      "retainerSchedule": "WEEKLY",
      "estimateMax": 0,
      "estimateMin": 0,
      "retainerStart": "2023-08-15",
      "retainerTiming": "ADVANCED",
      "retainerOverageRate": 0,
      "taxable": false,
      "fromProposalId": "",
      "fromProposalSignedDate": "2023-08-15T07:34:25.371-04:00",
      "updatedDate": "2023-08-15T07:34:25.371-04:00",
      "updatedBy": ""
    },
    "proposalId": "",
    "proposalName": "",
    "hexColor": "",
    "portalAccess": "FULL",
    "showTimeWorkedInPortal": false
  }
]
```

---

### 5. Search Payable Invoices

- **Method:** `GET`
- **Path:** `/action/payableInvoices/search?query=`
- **Parameters:**
  - `query` (optional) — client name filter
- **Response:** Array of invoice objects with nested `clientInfo` and `payments`

```json
[
  {
    "id": "",
    "invoiceNumber": 0,
    "invoiceNumberFormatted": "",
    "accountId": 0,
    "clientId": "",
    "dateCreated": "2023-08-15",
    "dateSent": "2023-08-15",
    "dateDue": "2023-08-15",
    "dateDueCalculated": "2023-08-15",
    "datePaid": "2023-08-15",
    "clientInfo": {
      "id": "",
      "name": "",
      "initials": "",
      "address1": "", "address2": "", "city": "", "locality": "", "postal": "", "country": "",
      "phone": "", "color": "", "taxId": "", "website": "",
      "contact": { "..." : "..." },
      "roundingIncrement": 0,
      "customInfo": false
    },
    "status": "SENT",
    "invoiceType": "STANDARD",
    "subTotal": 0,
    "convenienceFee": 0,
    "lateFee": 0,
    "discountAmount": 0,
    "creditApplied": 0,
    "tax": 0,
    "total": 0,
    "localTotal": 0,
    "paymentTotal": 0,
    "localPaymentTotal": 0,
    "amountDue": 0,
    "localAmountDue": 0,
    "currency": "",
    "integrationKeys": { "quickbooksId": "", "xeroId": "" },
    "viewOnlineUrl": "",
    "payments": [
      {
        "id": "",
        "amount": 0,
        "pending": false,
        "paidBy": "",
        "paymentProvider": "STRIPE",
        "currency": "",
        "referenceNumber": "",
        "memo": "",
        "datePaid": "2023-08-15",
        "timestamp": "2023-08-15T09:26:02.383-04:00",
        "integratedPayment": false,
        "forcePaidInFull": false,
        "integrationKeys": { "quickbooksId": "", "xeroId": "" },
        "isFailedPayment": false,
        "localAmount": 0
      }
    ]
  }
]
```

---

### 6. List Email Templates

- **Method:** `GET`
- **Path:** `/action/emailTemplates/list`
- **Parameters:** None
- **Response:** Array of strings

```json
["Email Template Name 1", "Email Template Name 2"]
```

---

### 7. List Invoice Templates

- **Method:** `GET`
- **Path:** `/action/invoiceTemplates/list`
- **Parameters:** None
- **Response:** Array of strings

```json
["Invoice Template Name 1", "Invoice Template Name 2"]
```

---

### 8. List Vendor Names

- **Method:** `GET`
- **Path:** `/action/vendors/list`
- **Parameters:** None
- **Response:** Array of strings

```json
["Vendor 1", "Vendor 2"]
```

---

### 9. List Form Names

- **Method:** `GET`
- **Path:** `/action/formNames/list`
- **Parameters:** None
- **Response:** Array of strings

```json
["Form Name 1", "Form Name 2"]
```

---

### 10. List Pipeline Stages

- **Method:** `GET`
- **Path:** `/action/pipelineStages/list`
- **Parameters:** None
- **Response:** Array of stage objects

```json
[
  {
    "id": "",
    "label": "",
    "hexColor": "",
    "stageType": "New"
  }
]
```

**Notes:**
- `stageType` values: `New`, `InProgress`, `OnHold`, `ClosedWon`, `ClosedLost`, `Complete`

---

### 11. List Project Task Stages

- **Method:** `GET`
- **Path:** `/action/taskStages/list`
- **Parameters:** None
- **Response:** Array of task stage objects

```json
[
  {
    "id": "",
    "label": "",
    "hexColor": "",
    "complete": false,
    "clientApproval": false
  }
]
```

---

### 12. List Workspace Users

- **Method:** `GET`
- **Path:** `/action/users/list`
- **Parameters:** None
- **Response:** Array of user objects

```json
[
  {
    "userType": "OWNER",
    "user": {
      "userId": 0,
      "firstName": "",
      "lastName": "",
      "email": "",
      "phone": "",
      "phoneVerified": false,
      "uuid": "",
      "profilePicture": "",
      "uploadedPicture": false,
      "pricingVersion": 0
    },
    "projectAccess": {
      "projects": [
        { "grantedAt": "2023-08-15T09:28:17.852-04:00", "projectId": "" }
      ]
    },
    "featureAccess": {
      "projects": false,
      "invoices": false,
      "accounting": false,
      "pipeline": false,
      "agreements": false,
      "settings": false,
      "timesheets": false,
      "tickets": false
    }
  }
]
```

**Notes:**
- `userType` values: `OWNER`, `FULL_USER`, `RESTRICTED_ACCESS`, `COLLABORATOR`
- `projectAccess` — populated only for `COLLABORATOR` users
- `featureAccess` — populated only for `RESTRICTED_ACCESS` users

---

## Create Endpoints

### 13. Create Client

- **Method:** `POST`
- **Path:** `/action/clients/create`
- **Request Body:**

```json
{
  "name": "",
  "clientType": "Client",
  "initials": "",
  "address1": "",
  "address2": "",
  "city": "",
  "locality": "",
  "postal": "",
  "country": "",
  "website": "",
  "phone": "",
  "color": "",
  "taxId": "",
  "leadSource": "",
  "archive": false,
  "paymentTerms": {
    "paymentDays": 0,
    "latePaymentFee": 0.00,
    "hourlyAmount": 0.00,
    "whoPaysCardFees": "Client"
  },
  "payInstructions": "",
  "hourlyAmount": 0.00,
  "roundingIncrement": 0,
  "currency": "USD",
  "stripeClientId": "",
  "notes": "",
  "contacts": [
    {
      "firstName": "",
      "lastName": "",
      "role": "",
      "phone": "",
      "email": "",
      "notes": "",
      "defaultContact": false,
      "invoiceContact": false,
      "portalAccess": false
    }
  ]
}
```

**Required fields:** `name`, `clientType`, `currency`

**Notes:**
- `clientType` — `"Client"` or `"Prospect"`
- `initials` — 3–4 characters for avatar and invoice number sequences
- `whoPaysCardFees` — `Client`, `Freelancer`, or `Split` (Stripe credit card fee pass-through at 2.99% / 1.5% / absorbed)
- `currency` — valid ISO 4217 code
- `stripeClientId` — Stripe customer ID (if integrated)
- `contacts[].defaultContact` — receives all client notifications
- `contacts[].invoiceContact` — receives invoice copies
- `contacts[].portalAccess` — can log into client portal

---

### 14. Create Contact

- **Method:** `POST`
- **Path:** `/action/contacts/create`
- **Request Body:**

```json
{
  "first": "",
  "last": "",
  "email": "",
  "phone": "",
  "notes": "",
  "clientName": "",
  "defaultContact": false,
  "portalAccess": false,
  "invoiceContact": false
}
```

**Notes:**
- `clientName` (optional) — exact match of existing client name; if found, contact is associated with that client

---

### 15. Create Invoice

- **Method:** `POST`
- **Path:** `/action/invoices/create`
- **Request Body:**

```json
{
  "invoiceNumber": "",
  "clientName": "",
  "templateName": "",
  "dueDate": "2023-07-20",
  "taxRate": 0.00,
  "discountPercent": 0.00,
  "paymentInstructions": "",
  "items": [
    {
      "description": "",
      "quantity": 0.00,
      "rate": 0.00,
      "taxable": false,
      "projectName": ""
    }
  ],
  "sendTo": {
    "send": true,
    "contacts": ["email@domain1.com", "email@domain2.com"],
    "emailTemplateName": ""
  }
}
```

**Required fields:** `clientName`, `items`

**Notes:**
- `clientName` — exact match of existing client
- `templateName` (optional) — exact match of pre-configured invoice template
- `items[].projectName` (optional) — exact match of project within the client
- `sendTo` (optional) — if omitted, invoice stays in DRAFT status
- `sendTo.emailTemplateName` (optional) — exact match; if omitted, default invoice email template is used

---

### 16. Create Expense

- **Method:** `POST`
- **Path:** `/action/expenses/create`
- **Request Body:**

```json
{
  "date": "2023-07-20T00:00:00.000+00:00",
  "amount": 0.00,
  "currency": "USD",
  "paid": false,
  "reimbursable": false,
  "markupPercentage": 0.00,
  "category": "",
  "billNo": "",
  "description": "",
  "notes": "",
  "vendor": "",
  "clientName": ""
}
```

**Required fields:** `currency`, `paid`, `reimbursable`

**Notes:**
- `currency` — valid ISO 4217 code
- `paid` — whether expense has already been paid
- `reimbursable` — eligible for reimbursement via Moxie invoicing
- `markupPercentage` (optional) — markup on reimbursable expenses on invoice
- `vendor` (optional) — exact match of vendor name
- `clientName` (optional) — exact match of client name

---

### 17. Create Form Submission

- **Method:** `POST`
- **Path:** `/action/formSubmissions/create`
- **Request Body:**

```json
{
  "formName": "",
  "firstName": "",
  "lastName": "",
  "email": "",
  "phone": "",
  "role": "",
  "businessName": "",
  "website": "",
  "address1": "",
  "address2": "",
  "city": "",
  "locality": "",
  "postal": "",
  "country": "",
  "sourceUrl": "",
  "leadSource": "",
  "notes": "",
  "pipelineStageName": "",
  "answers": [
    {
      "fieldKey": "",
      "question": "",
      "answer": ""
    }
  ]
}
```

**Notes:**
- `formName` (optional but recommended) — associate with existing form template for reporting
- `pipelineStageName` (optional) — exact match of pipeline stage; auto-creates an Opportunity
- `answers[]` (optional) — each requires `fieldKey`, `question`, and `answer`

---

### 18. Create Project

- **Method:** `POST`
- **Path:** `/action/projects/create`
- **Request Body:**

```json
{
  "name": "",
  "clientName": "",
  "templateName": "",
  "startDate": "2023-07-20",
  "dueDate": "2023-07-20",
  "portalAccess": "Full access",
  "showTimeWorkedInPortal": true,
  "feeSchedule": {
    "feeType": "Hourly",
    "amount": 0.00,
    "retainerSchedule": "WEEKLY",
    "estimateMax": 0,
    "estimateMin": 0,
    "retainerStart": "2023-07-20",
    "retainerTiming": "ADVANCED",
    "retainerOverageRate": 0.00,
    "taxable": false
  }
}
```

**Required fields:** `name`, `clientName`, `feeSchedule` (required when not using template)

**Notes:**
- `clientName` — exact match of existing client
- `templateName` (optional) — applies template settings including tasks
- `portalAccess` — one of: `None`, `Overview`, `Full access`, `Read only` (default: Read Only)
- `feeSchedule.feeType` — one of: `Hourly`, `Fixed Price`, `Retainer`, `Per Item`
- `retainerSchedule` — `WEEKLY`, `BI_WEEKLY`, `MONTHLY`, `QUARTERLY`, `BI_ANNUALLY`, `ANNUALLY`
- `retainerTiming` — `ADVANCED` (invoice before period) or `ARREARS` (invoice after period)

---

### 19. Create Task

- **Method:** `POST`
- **Path:** `/action/tasks/create`
- **Request Body:**

```json
{
  "name": "",
  "clientName": "",
  "projectName": "",
  "status": "",
  "description": "",
  "dueDate": "2023-07-20",
  "startDate": "2023-07-20",
  "priority": 1,
  "tasks": ["One", "Two", "Three"],
  "assignedTo": ["user1@withmoxie.com", "user2@withmoxie.com"],
  "customValues": {
    "Field1 name": "Field value",
    "Field2 name": "Field value"
  }
}
```

**Required fields:** `name`, `clientName`, `projectName`

**Notes:**
- `status` (optional) — must exactly match a kanban status
- `priority` (optional) — numeric sort order
- `tasks` — array of sub-task name strings
- `assignedTo` — email addresses of workspace users
- `customValues` — keys must exactly match custom field names in project settings

---

### 20. Create Ticket

- **Method:** `POST`
- **Path:** `/action/tickets/create`
- **Request Body:**

```json
{
  "userEmail": "user@email.com",
  "ticketType": "Fancy Support Request",
  "subject": "Please do some work for me!",
  "comment": "This is going to be a rad comment here.",
  "dueDate": "2024-06-01",
  "formData": {
    "answers": [
      {
        "fieldKey": "ProjectType",
        "question": "What type of project do you need?",
        "answer": "Website design"
      }
    ]
  }
}
```

**Required fields:** `userEmail`, `ticketType`, `comment`

**Notes:**
- `userEmail` — must be a known contact in the workspace (rejected if not found)
- `ticketType` — must match a ticket type from Tickets → Settings
- `formData` (optional) — structured Q&A for ticket data mapping

---

### 21. Create Comment on Ticket

- **Method:** `POST`
- **Path:** `/action/tickets/comments/create`
- **Request Body:**

```json
{
  "userEmail": "user@email.com",
  "ticketNumber": 10005,
  "privateComment": false,
  "comment": "This is going to be some rad comment here that is really awesome."
}
```

**Required fields:** `userEmail`, `ticketNumber`, `privateComment`, `comment`

**Notes:**
- `userEmail` — must be a known contact or team member (rejected if not found)
- `ticketNumber` — numeric ticket identifier
- `privateComment` — `true` for internal-only; ignored if `userEmail` belongs to a client contact

---

### 22. Create Opportunity

- **Method:** `POST`
- **Path:** `/action/opportunities/create`
- **Request Body:**

```json
{
  "name": "",
  "description": "",
  "clientName": "",
  "stageName": "",
  "value": 0.00,
  "estCloseDate": "2023-07-20",
  "leadInfo": {
    "firstName": "",
    "lastName": "",
    "email": "",
    "phone": "",
    "role": "",
    "businessName": "",
    "website": "",
    "address1": "",
    "address2": "",
    "city": "",
    "locality": "",
    "postal": "",
    "country": "",
    "sourceUrl": "",
    "leadSource": "",
    "answers": [
      { "fieldKey": "", "question": "", "answer": "" }
    ]
  },
  "toDos": [
    { "item": "Do something", "complete": false, "dueDate": "2023-07-20" }
  ],
  "customValues": {
    "Field1 Name": "Value",
    "Field2 name": "Value"
  }
}
```

**Required fields:** `name`

**Notes:**
- `clientName` (optional) — exact match of client
- `stageName` (optional) — exact match of pipeline stage name
- `leadInfo.answers[]` — each requires `fieldKey`, `question`, `answer`
- `customValues` — keys must exactly match pipeline custom field names

---

### 23. Create Time Entry

- **Method:** `POST`
- **Path:** `/action/timeWorked/create`
- **Request Body:**

```json
{
  "timerStart": "2023-07-20T13:04:07.654+01:00",
  "timerEnd": "2023-07-20T13:04:07.654+01:00",
  "clientName": "",
  "projectName": "",
  "deliverableName": "",
  "notes": "",
  "userEmail": "",
  "createClient": false,
  "createProject": false,
  "createDeliverable": false
}
```

**Required fields:** `timerStart`, `timerEnd`, `userEmail`

**Notes:**
- `timerStart` / `timerEnd` — ISO-8601 format; end must be after start
- `clientName`, `projectName`, `deliverableName` (optional) — exact matches
- `userEmail` — email of workspace user who owns the entry
- `createClient`, `createProject`, `createDeliverable` (optional) — if `true`, creates the record when no exact match found

---

## Action Endpoints

### 24. Approve Deliverable

- **Method:** `POST`
- **Path:** `/action/deliverable/approve`
- **Request Body:**

```json
{
  "clientName": "",
  "projectName": "",
  "deliverableName": ""
}
```

**Required fields:** `clientName`, `projectName`, `deliverableName` (all exact match)

**Notes:** Approves a deliverable currently in Client Workflow / Approval status on the Project Kanban.

---

### 25. Apply Payment to Invoice

- **Method:** `POST`
- **Path:** `/action/payment/create`
- **Request Body:**

```json
{
  "date": "2023-08-03",
  "amount": 13675.00,
  "invoiceNumber": "E-2023-79",
  "clientName": "Client Name",
  "paymentType": "BANK_TRANSFER",
  "referenceNumber": "123",
  "memo": "API Payment"
}
```

**Required fields:** `date`, `amount`, `invoiceNumber`

**Notes:**
- `date` — payment date; determines exchange rate in multi-currency environments
- `amount` — must not exceed amount owed
- `invoiceNumber` — Moxie invoice number
- `clientName` (optional) — required only if duplicate invoice numbers exist across clients
- `paymentType` (optional, default `OTHER`) — one of: `STRIPE`, `CHECK`, `BANK_TRANSFER`, `CASH`, `VENMO`, `PAYPAL`, `ZELLE`, `APP_PAYOUT`, `CREDIT_CARD`, `OTHER`

---

### 26. Attach File — Multipart Upload

- **Method:** `POST`
- **Path:** `/action/attachments/create`
- **Content-Type:** `multipart/form-data`
- **Form Fields:**
  - `type` (required) — one of: `CLIENT`, `PROJECT`, `DELIVERABLE`, `OPPORTUNITY`, `EXPENSE`, `TICKET`
  - `id` (required) — unique identifier of the target object
  - `file` (required) — file upload, max 100 MB

**Response:** Auto-expiring signed download URL (expires 15 minutes after creation).

---

### 27. Attach File — From URL

- **Method:** `POST`
- **Path:** `/action/attachments/createFromUrl`
- **Content-Type:** `multipart/form-data`
- **Form Fields:**
  - `type` (required) — one of: `CLIENT`, `PROJECT`, `DELIVERABLE`, `OPPORTUNITY`, `EXPENSE`, `TICKET`
  - `id` (required) — unique identifier of the target object
  - `fileName` (required) — name for the attached file
  - `fileUrl` (required) — valid HTTPS URL; Moxie server fetches the file

**Response:** Auto-expiring signed download URL (expires 15 minutes after creation).

---

### 28. Create or Update Calendar Event

- **Method:** `POST`
- **Path:** `/action/calendar/createOrUpdate`
- **Request Body:**

```json
{
  "eventId": "your unique event id",
  "startTime": "2024-07-06T08:00:00",
  "endTime": "2024-07-06T08:30:00",
  "timezone": "America/New_York",
  "summary": "Title of the event",
  "description": "Long description of event",
  "location": "Typically an online location or physical address",
  "busy": true,
  "userEmail": "email@domain.com"
}
```

**Notes:**
- `eventId` — typically an ICS Calendar Event ID; used for update/delete linking
- `startTime` / `endTime` — ISO date/time **without** timezone offset (timezone specified separately)
- `timezone` — IANA timezone (e.g., `America/New_York`, `Europe/London`)
- `busy` — `true` blocks scheduling availability
- `userEmail` (optional) — event owner; defaults to workspace owner if invalid/omitted

---

### 29. Delete Calendar Event

- **Method:** `DELETE`
- **Path:** `/action/calendar/{eventId}`
- **Parameters:** `eventId` in URL path — corresponds to the `eventId` from Create/Update
- **Request Body:** None

---

## General Notes & Gotchas

1. **Exact name matching** — Most create endpoints require exact string matches for `clientName`, `projectName`, `stageName`, `templateName`, etc. Partial matches will not work.
2. **Rate limiting** — 100 requests per 5 minutes. Plan bulk operations accordingly.
3. **File uploads** — Both attachment endpoints use `multipart/form-data`, not JSON. Max file size: 100 MB.
4. **Download URLs expire** — File attachment responses return signed URLs that expire after 15 minutes.
5. **Multi-currency** — Payment dates affect exchange rates. Invoice currency comes from the client record.
6. **Draft invoices** — Omitting `sendTo` on invoice creation leaves the invoice in DRAFT status.
7. **Auto-creation** — Only the Time Entry endpoint supports `createClient`/`createProject`/`createDeliverable` flags for auto-creating missing records.
8. **Contact validation** — Ticket endpoints validate `userEmail` against known contacts/users and reject unknown emails.
9. **Pipeline stage types** — `New`, `InProgress`, `OnHold`, `ClosedWon`, `ClosedLost`, `Complete`.
10. **User types** — `OWNER`, `FULL_USER`, `RESTRICTED_ACCESS`, `COLLABORATOR` — each with different access models.
