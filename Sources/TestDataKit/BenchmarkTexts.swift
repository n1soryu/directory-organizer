import Foundation

// The benchmark's corpus (~/Developer/mlx-experiment, REPORT.md), copied verbatim: 27 short text
// files about fictional people and companies. Generated from the benchmark's corpus folder; never
// edit the texts. For measuring only: never use them, or anything about them, in a prompt.

extension BenchmarkCorpus {
    public static let texts: [String: String] = [
        "Bill-2026-06.txt": #"""
Contoso Water Utility
Water & Sewerage Bill

Account holder: Alex Rahman
Account no.: CW-90817
Supply address: 14 Elm Road, Apt 3B, Riverton
Bill period: June 2026 (2026-06-01 – 2026-06-30)
Bill date: 2026-07-04

Previous reading: 1,102 m³
Present reading:  1,116 m³
Consumption: 14 m³

Water supply charge        420.00
Sewerage charge            150.00
Service fee                 40.00
---------------------------------
Amount due                 610.00
Due date: 2026-07-20

Reference: CW-INV-260604-1187
Thank you for saving water.

"""#,
        "Bill-2026-07.txt": #"""
Contoso Water Utility
Water & Sewerage Bill

Account holder: Alex Rahman
Account no.: CW-90817
Supply address: 14 Elm Road, Apt 3B, Riverton
Bill period: July 2026 (2026-07-01 – 2026-07-31)
Bill date: 2026-08-04

Previous reading: 1,116 m³
Present reading:  1,132 m³
Consumption: 16 m³

Water supply charge        480.00
Sewerage charge            170.00
Service fee                 40.00
---------------------------------
Amount due                 690.00
Due date: 2026-08-20

Reference: CW-INV-260804-2291
Thank you for saving water.

"""#,
        "IMG_2231.txt": #"""
BLUE FERN CAFE
5 Garden Lane, Riverton

Receipt #00482
2026-09-14  09:12

2 x Latte (regular)          520.00
1 x Butter croissant         220.00
                           ---------
TOTAL                        740.00

Paid: Cash 1,000.00
Change: 260.00

Free Wi-Fi: BlueFern-Guest
Thanks, see you again!

"""#,
        "Lecture 6.txt": #"""
Riverton University — Department of Mathematics
STAT101 Introduction to Statistics
Lecture 6: Hypothesis Testing

Learning goals
- State null and alternative hypotheses.
- Compute and interpret a test statistic and p-value.
- Understand Type I and Type II errors.

1. H0: the default claim; H1: what we look for evidence of.
2. Test statistic z = (x̄ − μ0) / (σ/√n).
3. Reject H0 when p-value < α (often 0.05).
4. Type I error: rejecting a true H0. Type II: failing to reject a false H0.
5. Example: x̄ = 52, μ0 = 50, σ = 6, n = 36 → z = 2.0, p ≈ 0.046.

Reading: Chapter 8, sections 8.1–8.4
Quiz 2 next Tuesday.

"""#,
        "UM_HD12.txt": #"""
BRIGHTLINE HD12 HIGH-SPEED BLENDER
Instruction Manual

Thank you for choosing Brightline.

ASSEMBLY
1. Place the motor base on a dry, level surface.
2. Fit the blade assembly into the jug and twist clockwise to lock.
3. Put the jug on the base and secure the lid before use.

SPEED SETTINGS
1 – Stir   2 – Mix   3 – Blend   4 – Purée   P – Pulse
Do not run continuously for more than 60 seconds.

CLEANING
Unplug before cleaning. Jug, lid and blades are dishwasher safe (top rack).
Wipe the motor base with a damp cloth; never immerse it in water.

WARRANTY
Brightline Appliances warrants the HD12 against manufacturing defects for
2 years from the date of purchase. Keep your proof of purchase.
Model: HD12 | 230 V ~ 50 Hz | 1200 W

"""#,
        "agreement_final.txt": #"""
RESIDENTIAL LEASE AGREEMENT

This agreement is made between Mira Holdings Ltd ("Landlord"),
88 Market Street, Riverton, and Alex Rahman ("Tenant").

Premises: 14 Elm Road, Apartment 3B, Riverton
Term: 2025-10-01 to 2026-09-30 (twelve months)
Monthly rent: 18,000, payable in advance on the 1st of each month
Security deposit: 36,000

1. The Tenant shall use the premises as a private residence only.
2. Utilities (electricity, water) are paid by the Tenant.
3. The Tenant shall not sublet without written consent.
4. Either party may end the lease at term end with 60 days' notice.
5. The Landlord is responsible for structural repairs.

Signed: For Mira Holdings Ltd — R. Mirza, Director     Date: 2025-09-15
Signed: Alex Rahman, Tenant                            Date: 2025-09-15

"""#,
        "boarding_pass.txt": #"""
SKYBRIDGE AIRWAYS
BOARDING PASS

Passenger: RAHMAN/ALEX MR
Flight: SB 214
From: DAC Dhaka           To: SIN Singapore
Date: 2026-07-03
Departure: 23:55          Boarding: 23:15
Gate: B7                  Seat: 14C
Class: Economy            Zone: 3
Booking ref: QX7L2M       E-ticket: 618-2234019875
Baggage: 1 x 23 kg

Gate closes 20 minutes before departure.

"""#,
        "cover_letter.txt": #"""
Alex Rahman
14 Elm Road, Apt 3B, Riverton
alex.rahman@example.com | 555-0177

2026-09-05

Hiring Manager
Tailspin Analytics
40 Harbour Way, Riverton

Dear Hiring Manager,

I am writing to apply for the Data Analyst role at Tailspin Analytics. In my
current position I build weekly sales dashboards, clean large datasets in SQL
and Python, and present findings to non-technical teams.

I am drawn to Tailspin's work on retail forecasting, and I would welcome the
chance to bring my statistics background and attention to detail to your team.

Thank you for considering my application. I look forward to hearing from you.

Sincerely,
Alex Rahman

"""#,
        "document (4).txt": #"""
ALEX RAHMAN
14 Elm Road, Apt 3B, Riverton | alex.rahman@example.com | 555-0177

PROFILE
Data analyst with four years' experience turning raw data into clear
business decisions.

EXPERIENCE
Business Intelligence Analyst, Fabrikam Ltd — 2023 to present
- Built weekly sales dashboards used by 40 managers.
- Automated reporting in SQL and Python, saving 10 hours a week.
Junior Analyst, Litware Retail — 2021 to 2023
- Cleaned and merged store sales data across 25 branches.

EDUCATION
BSc in Statistics, Riverton University — 2021

SKILLS
SQL, Python (pandas), Excel, Tableau, A/B testing, regression analysis

LANGUAGES
English, Bengali

"""#,
        "download.txt": #"""
NORTHWIND ELECTRIC
Customer Service: 0800-555-0142 | www.northwind-electric.example
Electricity Statement

Customer: Alex Rahman
Service address: 14 Elm Road, Apt 3B, Riverton
Account number: 4471-220
Statement date: 2026-08-25
Billing period: 2026-08-01 to 2026-08-31 (August 2026)

Meter reading (previous): 18,616 kWh
Meter reading (current):  19,071 kWh
Energy used: 455 kWh

Energy charge (455 kWh)          2,275.00
Fixed service charge               180.00
Meter rent                          40.00
VAT                                117.00
--------------------------------------------
Amount due                       2,612.00
Payment due by: 2026-09-10

Pay online, by bank transfer, or at any Northwind payment point.
Late payments may incur a surcharge of 2%.

"""#,
        "form.txt": #"""
CITY OF RIVERTON — ANIMAL SERVICES
DOG LICENCE RENEWAL APPLICATION

Section 1: Owner
Name: Alex Rahman
Address: 14 Elm Road, Apt 3B, Riverton
Phone: 555-0177

Section 2: Dog
Name: Biscuit
Breed: Beagle mix     Sex: Female     Colour: Tan and white
Date of birth: 2022-04-18
Microchip no.: 985112004417736
Rabies vaccination valid until: 2027-03-01

Section 3: Licence
Licence no.: RIV-DOG-22-0918
Renewal period: 2026-11-01 to 2027-10-31
Fee: 500.00 (neutered/spayed: 250.00)

I confirm the information above is correct.
Owner signature: ____________   Date: __________

"""#,
        "grinder.txt": #"""
EMBER CG-2 CONICAL COFFEE GRINDER
User Manual

Getting started
Remove all packaging. Wash the bean hopper and grounds bin in warm soapy water
and dry them fully before first use.

Grind settings
Turn the dial to choose from 18 settings:
1–4 Espresso   5–9 Pour-over   10–14 Drip   15–18 French press
Adjust only while the grinder is running.

Cleaning
Unplug first. Remove the upper burr by twisting anticlockwise and brush away
old grounds. Never use water on the burrs. Clean every two weeks.

Safety
Keep fingers away from the burrs. Do not grind anything other than roasted
coffee beans. Not for use by children.
Ember Home Appliances | Model CG-2 | 220–240 V | 150 W

"""#,
        "manual_v2.txt": #"""
Kestrel AX-300 Wi-Fi 6 Router
User Guide — Version 2.0

1. In the box
   AX-300 router, power adapter, Ethernet cable, quick start card.

2. Setup
   Connect the WAN port to your modem. Power on the router and wait for the
   status LED to turn solid white. Join the network printed on the label and
   open http://192.168.0.1 to run the setup wizard.

3. LED meanings
   Solid white: connected to the internet.
   Blinking white: starting up or updating firmware.
   Solid amber: no internet connection.
   Blinking amber: WPS pairing in progress.

4. Factory reset
   With the router on, hold the RESET button for 10 seconds until the LED blinks amber.
   All settings return to factory defaults.

5. Safety
   Use only the supplied adapter. Keep away from water and heat sources.
   Do not open the casing. Kestrel Networks, Model AX-300, FCC ID: KST-AX300.

"""#,
        "notice.txt": #"""
MIRA HOLDINGS LTD
88 Market Street, Riverton

2026-08-20

To: Alex Rahman
14 Elm Road, Apartment 3B, Riverton

TENANCY RENEWAL NOTICE

Dear Alex Rahman,

Your current lease for 14 Elm Road, Apartment 3B ends on 2026-09-30.
We are pleased to offer a renewal on the following terms:

New term: 2026-10-01 to 2027-09-30
New monthly rent: 19,000 (previously 18,000)
All other terms remain unchanged.

Please sign and return the attached renewal form by 2026-09-10.

Kind regards,
R. Mirza, Director, Mira Holdings Ltd

"""#,
        "nw_news_oct.txt": #"""
NORTHWIND ELECTRIC — CUSTOMER NEWS
October 2026

Hello from your energy team!

Five ways to save energy this autumn
- Switch to LED bulbs: they use up to 80% less power.
- Run washing machines on full loads at 30 °C.
- Unplug chargers and standby devices overnight.
- Seal gaps around doors and windows.
- Set your water heater to 55 °C.

Community Solar Day
Join us on 2026-10-24 at Riverton Park to learn about rooftop solar
panels, meet installers and try our energy-use quiz. Free entry.

We're hiring
Visit our new careers page at northwind-electric.example/careers to see
open roles in engineering and customer care.

You are receiving this newsletter as a Northwind customer.
Unsubscribe at any time.

"""#,
        "payslip (1).txt": #"""
FABRIKAM LTD
Payslip — September 2026

Employee: Alex Rahman          Employee ID: FAB-0412
Department: Business Intelligence
Pay period: 2026-09-01 to 2026-09-30   Pay date: 2026-09-30

EARNINGS
Basic salary                     85,000.00
Transport allowance               5,000.00
Overtime                          3,400.00
Gross pay                        93,400.00

DEDUCTIONS
Income tax                        9,340.00
Provident fund                    4,250.00
Health insurance                  1,200.00
Total deductions                 14,790.00

NET PAY                          78,610.00
Paid to bank account ****2209

"""#,
        "payslip.txt": #"""
FABRIKAM LTD
Payslip — August 2026

Employee: Alex Rahman          Employee ID: FAB-0412
Department: Business Intelligence
Pay period: 2026-08-01 to 2026-08-31   Pay date: 2026-08-31

EARNINGS
Basic salary                     85,000.00
Transport allowance               5,000.00
Gross pay                        90,000.00

DEDUCTIONS
Income tax                        9,000.00
Provident fund                    4,250.00
Health insurance                  1,200.00
Total deductions                 14,450.00

NET PAY                          75,550.00
Paid to bank account ****2209

"""#,
        "rcpt_march.txt": #"""
MIRA HOLDINGS LTD
88 Market Street, Riverton
RENT RECEIPT No. MH-R-2603-117

Date: 2026-03-02
Received from: Alex Rahman
Property: 14 Elm Road, Apartment 3B
For: Rent for March 2026
Amount received: 18,000
Payment method: Bank transfer (ref. 7781-ELM3B)

Balance outstanding: 0

Received by: S. Akter, Accounts

"""#,
        "receipt.txt": #"""
HARBOR GRILL
22 Quay Street, Riverton | Tel 555-0199
VAT Reg: HG-778120

Date: 2026-08-02   Time: 20:41
Table: 7   Guests: 2   Server: Jonah

1 x Grilled Sea Bass                 1,050.00
1 x Ribeye Steak                     1,240.00
1 x Garden Salad                       280.00
2 x Fresh Lime Soda                    240.00
1 x Chocolate Fondant                  220.00
                                   -----------
Subtotal                             3,030.00
Service charge                         150.00
TOTAL                                3,180.00

Paid by: VISA card ****4417
Auth code: 093321
Thank you for dining with us!

"""#,
        "report.txt": #"""
LAKESIDE CLINIC — LABORATORY REPORT
12 Lakeview Avenue, Riverton | Lab ID: LC-LAB-1002-518

Patient: Alex Rahman          DOB: 1994-03-11
Sample collected: 2026-10-02  Reported: 2026-10-02
Referring physician: Dr. Nadia Karim
Reason: Follow-up after starting atorvastatin

LIPID PANEL                    Result     Reference range
Total cholesterol              192 mg/dL  < 200
LDL cholesterol                118 mg/dL  < 130
HDL cholesterol                 47 mg/dL  > 40
Triglycerides                  139 mg/dL  < 150

Comment: All lipid values now within reference range.

Verified by: M. Ortega, Lab Scientist

"""#,
        "results_0815.txt": #"""
LAKESIDE CLINIC — LABORATORY REPORT
12 Lakeview Avenue, Riverton | Lab ID: LC-LAB-0815-334

Patient: Alex Rahman          DOB: 1994-03-11
Sample collected: 2026-08-15  Reported: 2026-08-15
Referring physician: Dr. Nadia Karim

COMPLETE BLOOD COUNT (CBC)     Result     Reference range
Haemoglobin                    14.2 g/dL  13.0 – 17.0
White cell count               6.8        4.0 – 11.0 x10^9/L
Platelets                      245        150 – 400 x10^9/L

LIPID PANEL
Total cholesterol              236 mg/dL  < 200        HIGH
LDL cholesterol                158 mg/dL  < 130        HIGH
HDL cholesterol                 44 mg/dL  > 40
Triglycerides                  170 mg/dL  < 150        HIGH

Verified by: M. Ortega, Lab Scientist

"""#,
        "rx.txt": #"""
LAKESIDE CLINIC
12 Lakeview Avenue, Riverton | Tel 555-0123

PRESCRIPTION

Date: 2026-08-16
Patient: Alex Rahman      Age: 32
Prescriber: Dr. Nadia Karim, MD (Reg. 55102)

Rx
Atorvastatin 10 mg tablets
Sig: Take one tablet by mouth once daily at night.
Quantity: 30 tablets    Refills: 2

Notes: Review lipid panel in 6 weeks.

Signature: N. Karim

"""#,
        "scan_0932.txt": #"""
Contoso Water Utility
Water & Sewerage Bill

Account holder: Alex Rahman
Account no.: CW-90817
Supply address: 14 Elm Road, Apt 3B, Riverton
Bill period: September 2026 (2026-09-01 – 2026-09-30)
Bill date: 2026-10-04

Previous reading: 1,163 m³
Present reading:  1,178 m³
Consumption: 15 m³

Water supply charge        450.00
Sewerage charge            160.00
Service fee                 40.00
---------------------------------
Amount due                 650.00
Due date: 2026-10-20

Reference: CW-INV-261004-3054
Thank you for saving water.

"""#,
        "stat101_lec5.txt": #"""
Riverton University — Department of Mathematics
STAT101 Introduction to Statistics
Lecture 5: Sampling Distributions

Learning goals
- Distinguish a population parameter from a sample statistic.
- Describe the sampling distribution of the sample mean.
- Apply the Central Limit Theorem.

1. Statistics vary from sample to sample.
2. The sampling distribution of x̄ has mean μ and standard error σ/√n.
3. Central Limit Theorem: for large n, x̄ is approximately normal,
   whatever the shape of the population.
4. Example: n = 36, σ = 12 → standard error = 2.

Reading: Chapter 7, sections 7.1–7.3
Problem set 3 due next week.

"""#,
        "statement_0712.txt": #"""
NORTHWIND ELECTRIC
Customer Service: 0800-555-0142 | www.northwind-electric.example
Electricity Statement

Customer: Alex Rahman
Service address: 14 Elm Road, Apt 3B, Riverton
Account number: 4471-220
Statement date: 2026-07-25
Billing period: 2026-07-01 to 2026-07-31 (July 2026)

Meter reading (previous): 18,204 kWh
Meter reading (current):  18,616 kWh
Energy used: 412 kWh

Energy charge (412 kWh)          2,060.00
Fixed service charge               180.00
Meter rent                          40.00
VAT                                 60.50
--------------------------------------------
Amount due                       2,340.50
Payment due by: 2026-08-10

Pay online, by bank transfer, or at any Northwind payment point.
Late payments may incur a surcharge of 2%.

"""#,
        "ticket.txt": #"""
ORBIT AIR
BOARDING PASS

Passenger: RAHMAN/ALEX
Flight: OA 88
From: SIN Singapore       To: DAC Dhaka
Date: 2026-07-12
Departure: 14:20          Boarding: 13:40
Gate: C21                 Seat: 22A
Class: Economy            Group: 4
Booking ref: ZP4K9T

Please be at the gate by boarding time.

"""#,
        "welcome.txt": #"""
PeakFit Gym
Welcome to the PeakFit family!

Dear Alex Rahman,

Thank you for joining PeakFit Riverton. Your membership details are below.

Member name: Alex Rahman
Member number: PF-20931
Plan: Monthly Standard (all-day access)
Start date: 2026-06-01
Monthly fee: 2,500.00, charged on the 1st of each month

Membership terms
1. The plan renews monthly until cancelled with 30 days' written notice.
2. Your member card is personal and may not be shared.
3. Towels and lockers are available at reception.
4. PeakFit may change opening hours with 14 days' notice.

See you on the floor!
The PeakFit Team

"""#,
    ]
}
