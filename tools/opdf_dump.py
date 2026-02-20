import struct

with open('TeaserDemo', 'rb') as f:
    data = f.read()

# Find .opdf section via ELF headers
# Quick hack: find 'OPDF' magic
idx = data.find(b'OPDF')
if idx == -1:
    print('OPDF not found')
    exit()

print(f'OPDF magic at offset 0x{idx:x}')
pos = idx + 32  # skip header

rec_names = {0:'Unknown',1:'Primitive',2:'GlobalVar',3:'ShortStr',4:'AnsiStr',5:'UnicodeStr',
             6:'Pointer',7:'Array',8:'Record',9:'Class',10:'Property',11:'Method',
             12:'LocalVar',13:'Parameter',14:'LineInfo',15:'FuncScope',16:'Interface',17:'Enum',
             18:'Set'}

count = 0
while pos + 5 <= len(data) and count < 80:
    rec_type = data[pos]
    rec_size = struct.unpack_from('<I', data, pos+1)[0]
    name = rec_names.get(rec_type, f'?({rec_type})')
    print(f'  [{count:3d}] offset=0x{pos:x} type={rec_type:2d} ({name:12s}) size={rec_size}')
    pos += 5 + rec_size
    count += 1
    if rec_size == 0 or rec_size > 100000:
        print('  *** BAD SIZE, stopping')
        break

print(f'Total records parsed: {count}')
print(f'Final position: 0x{pos:x}, data ends at 0x{len(data):x}')
