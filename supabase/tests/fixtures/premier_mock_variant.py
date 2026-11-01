# LOCAL TEST ONLY: writes a variant of the MOCK Premier export (member 687990338 unpaid / re-paid) for local_test_hub_cutover.sh
# usage: premier_mock_variant.py SRC DST unpaid|paid2
import csv,io,sys
src,dst,mode=sys.argv[1:4]
raw=open(src,'rb').read().decode('cp1252'); rows=list(csv.reader(io.StringIO(raw,newline=''))); h=rows[0]
for r in rows[1:]:
    if r[2]=='687990338' and mode=='unpaid':
        r[h.index('Paid')]='No'; r[h.index('Last Payment')]='0'; r[h.index('First Billing Date')]=''
    if mode=='paid2' and r[2]=='687990338':
        r[h.index('Phone 2')]='2125550199'   # distinct file, same pay facts as the original
buf=io.StringIO(); csv.writer(buf,lineterminator='\r\n').writerows(rows)
open(dst,'wb').write(buf.getvalue().encode('cp1252'))
