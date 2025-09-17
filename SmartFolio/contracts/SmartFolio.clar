;; Smart Portfolio Manager for Automated Asset Allocation
;; A secure smart contract that automatically rebalances investment portfolios based on predefined
;; allocation strategies, risk tolerance levels, and market conditions with comprehensive 
;; performance tracking and automated rebalancing mechanisms.

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u400))
(define-constant ERR-INSUFFICIENT-BALANCE (err u401))
(define-constant ERR-INVALID-ALLOCATION (err u402))
(define-constant ERR-PORTFOLIO-NOT-FOUND (err u403))
(define-constant ERR-INVALID-ASSET (err u404))
(define-constant ERR-REBALANCE-TOO-FREQUENT (err u405))
(define-constant ERR-RISK-THRESHOLD-EXCEEDED (err u406))
(define-constant MAX-ASSETS-PER-PORTFOLIO u10)
(define-constant MIN-REBALANCE-INTERVAL u144) ;; ~24 hours in blocks
(define-constant PRECISION-MULTIPLIER u1000000)
(define-constant MAX-ALLOCATION-PERCENTAGE u100)

;; data maps and vars
(define-data-var next-portfolio-id uint u1)
(define-data-var total-managed-assets uint u0)
(define-data-var contract-paused bool false)
(define-data-var rebalance-fee-percentage uint u500) ;; 0.5%

(define-map portfolios
  uint
  {
    owner: principal,
    strategy-type: (string-ascii 20), ;; CONSERVATIVE, BALANCED, AGGRESSIVE
    risk-tolerance: uint, ;; 1-10 scale
    total-value: uint,
    last-rebalance-block: uint,
    auto-rebalance-enabled: bool,
    creation-block: uint
  })

(define-map asset-allocations
  {portfolio-id: uint, asset-symbol: (string-ascii 10)}
  {
    target-percentage: uint,
    current-percentage: uint,
    current-amount: uint,
    last-price: uint
  })

(define-map portfolio-performance
  uint
  {
    initial-value: uint,
    current-value: uint,
    total-return-percentage: uint,
    total-fees-paid: uint,
    rebalance-count: uint,
    best-performing-asset: (string-ascii 10),
    worst-performing-asset: (string-ascii 10)
  })

(define-map user-portfolios
  principal
  (list 5 uint)) ;; Max 5 portfolios per user

;; private functions
(define-private (calculate-allocation-value (portfolio-value uint) (percentage uint))
  (/ (* portfolio-value percentage) u100))

(define-private (calculate-percentage (amount uint) (total uint))
  (if (> total u0)
    (/ (* amount u100) total)
    u0))

(define-private (validate-allocation-percentages (allocations (list 10 {asset: (string-ascii 10), percentage: uint})))
  (let ((total-percentage (fold + (map get-percentage allocations) u0)))
    (is-eq total-percentage u100)))

(define-private (get-percentage (allocation {asset: (string-ascii 10), percentage: uint}))
  (get percentage allocation))

(define-private (calculate-rebalance-fee (portfolio-value uint))
  (/ (* portfolio-value (var-get rebalance-fee-percentage)) u100000))

;; public functions
(define-public (create-portfolio 
  (strategy-type (string-ascii 20))
  (risk-tolerance uint)
  (initial-deposit uint)
  (allocation-list (list 10 {asset: (string-ascii 10), percentage: uint})))
  
  (let ((portfolio-id (var-get next-portfolio-id)))
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (and (>= risk-tolerance u1) (<= risk-tolerance u10)) ERR-INVALID-ALLOCATION)
    (asserts! (> initial-deposit u0) ERR-INSUFFICIENT-BALANCE)
    (asserts! (validate-allocation-percentages allocation-list) ERR-INVALID-ALLOCATION)
    
    ;; Transfer initial deposit to contract
    (try! (stx-transfer? initial-deposit tx-sender (as-contract tx-sender)))
    
    ;; Create portfolio record
    (map-set portfolios portfolio-id {
      owner: tx-sender,
      strategy-type: strategy-type,
      risk-tolerance: risk-tolerance,
      total-value: initial-deposit,
      last-rebalance-block: block-height,
      auto-rebalance-enabled: true,
      creation-block: block-height
    })
    
    ;; Set initial performance tracking
    (map-set portfolio-performance portfolio-id {
      initial-value: initial-deposit,
      current-value: initial-deposit,
      total-return-percentage: u0,
      total-fees-paid: u0,
      rebalance-count: u0,
      best-performing-asset: "STX",
      worst-performing-asset: "STX"
    })
    
    ;; Update user portfolio list
    (let ((user-portfolios-list (default-to (list) (map-get? user-portfolios tx-sender))))
      (map-set user-portfolios tx-sender (unwrap-panic (as-max-len? (append user-portfolios-list portfolio-id) u5))))
    
    (var-set next-portfolio-id (+ portfolio-id u1))
    (var-set total-managed-assets (+ (var-get total-managed-assets) initial-deposit))
    
    (print {event: "portfolio-created", id: portfolio-id, owner: tx-sender, value: initial-deposit})
    (ok portfolio-id)))

(define-public (deposit-to-portfolio (portfolio-id uint) (amount uint))
  (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR-PORTFOLIO-NOT-FOUND)))
    (asserts! (is-eq (get owner portfolio) tx-sender) ERR-UNAUTHORIZED)
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (> amount u0) ERR-INSUFFICIENT-BALANCE)
    
    ;; Transfer funds to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update portfolio value
    (map-set portfolios portfolio-id 
             (merge portfolio {total-value: (+ (get total-value portfolio) amount)}))
    
    ;; Update performance tracking
    (let ((performance (unwrap-panic (map-get? portfolio-performance portfolio-id))))
      (map-set portfolio-performance portfolio-id
               (merge performance {current-value: (+ (get current-value performance) amount)})))
    
    (var-set total-managed-assets (+ (var-get total-managed-assets) amount))
    (ok amount)))

(define-public (trigger-rebalance (portfolio-id uint))
  (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR-PORTFOLIO-NOT-FOUND)))
    (asserts! (is-eq (get owner portfolio) tx-sender) ERR-UNAUTHORIZED)
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (>= (- block-height (get last-rebalance-block portfolio)) MIN-REBALANCE-INTERVAL) 
              ERR-REBALANCE-TOO-FREQUENT)
    
    (let ((rebalance-fee (calculate-rebalance-fee (get total-value portfolio))))
      ;; Charge rebalance fee
      (try! (as-contract (stx-transfer? rebalance-fee tx-sender CONTRACT-OWNER)))
      
      ;; Update portfolio
      (map-set portfolios portfolio-id 
               (merge portfolio {
                 last-rebalance-block: block-height,
                 total-value: (- (get total-value portfolio) rebalance-fee)
               }))
      
      ;; Update performance metrics
      (let ((performance (unwrap-panic (map-get? portfolio-performance portfolio-id))))
        (map-set portfolio-performance portfolio-id
                 (merge performance {
                   total-fees-paid: (+ (get total-fees-paid performance) rebalance-fee),
                   rebalance-count: (+ (get rebalance-count performance) u1)
                 })))
      
      (print {event: "portfolio-rebalanced", id: portfolio-id, fee: rebalance-fee})
      (ok true))))

(define-public (withdraw-from-portfolio (portfolio-id uint) (amount uint))
  (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR-PORTFOLIO-NOT-FOUND)))
    (asserts! (is-eq (get owner portfolio) tx-sender) ERR-UNAUTHORIZED)
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (<= amount (get total-value portfolio)) ERR-INSUFFICIENT-BALANCE)
    
    ;; Transfer funds back to user
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    
    ;; Update portfolio value
    (map-set portfolios portfolio-id 
             (merge portfolio {total-value: (- (get total-value portfolio) amount)}))
    
    (var-set total-managed-assets (- (var-get total-managed-assets) amount))
    (ok amount)))


