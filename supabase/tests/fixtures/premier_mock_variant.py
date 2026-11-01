# LOCAL TEST ONLY: writes a variant of the MOCK Premier export (member 687990338 unpaid / re-paid) for local_test_hub_cutover.sh
# usage: premier_mock_variant.py SRC DST unpaid|paid2|refund338|addon114
#   refund338: member 687990338 fully refunded + inactive 10/20 (a hub-era refund: clawback payday 10/23)
#   addon114:  member 687990114 gets a later Wellness4You add-on on the original deal (spiffs 75 -> 95)
import csv,io,sys
src,dst,mode=sys.argv[1:4]
raw=open(src,'rb').read().decode('cp1252'); rows=list(csv.reader(io.StringIO(raw,newline=''))); h=rows[0]
for r in rows[1:]:
    if r[2]=='687990338' and mode=='unpaid':
        r[h.index('Paid')]='No'; r[h.index('Last Payment')]='0'; r[h.index('First Billing Date')]=''
    if mode=='paid2' and r[2]=='687990338':
        r[h.index('Phone 2')]='2125550199'   # distinct file, same pay facts as the original
for r in rows[1:]:
    if mode=='refund338' and r[2]=='687990338':
        for k in ('Inactive Date','Refund Requested Date','Refund Provided Date','Inactive Date Set'): r[h.index(k)]='10/20/2026'
        r[h.index('Inactive Reason')]='Financial Reasons: Payment Dispute'; r[h.index('Refund Requested')]='Yes'; r[h.index('Refund Provided')]='Yes'
rows+=[[*r[:45], '47512', 'Wellness4You', 'Member', *r[48:]] for r in rows[1:]
        if mode=='addon114' and r[2]=='687990114' and r[h.index('Product ID')]=='48276']
buf=io.StringIO(); csv.writer(buf,lineterminator='\r\n').writerows(rows)
open(dst,'wb').write(buf.getvalue().encode('cp1252'))
