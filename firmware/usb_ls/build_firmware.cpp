// SPDX-License-Identifier: Apache-2.0
// Label-resolving image builder, not a USB controller. All emitted operations
// execute in protocol_engine. Run from repository root; see docs/usb.md.
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
using namespace std;
struct Image {
    vector<unsigned> words;
    map<string,unsigned> labels;
    struct Ref { unsigned at, op; string name; };
    vector<Ref> refs;
    void label(const string &s) { if (!labels.emplace(s, words.size()).second) throw runtime_error("duplicate label " + s); }
    void emit(unsigned w) { if (w > 65535) throw runtime_error("word overflow"); words.push_back(w); }
    void ref(unsigned op, const string &s) { refs.push_back({unsigned(words.size()),op,s}); emit(op); }
    void j(const string &s) { ref(0x4000,s); }
    void call(const string &s) { ref(0xf400,s); }
    void eq(const string &s) { emit(0x0f01); j(s); }
    void ne(const string &s) { emit(0x0f00); j(s); }
    void lt(const string &s) { emit(0x0f03); j(s); }
    void ldi(unsigned n) { emit(0x0100 | (n & 255)); }
    void ld(unsigned n) { emit(0x0200 | n); }
    void st(unsigned n) { emit(0x0300 | n); }
    void set(unsigned n,unsigned v) { ldi(v); st(n); }
    void add(unsigned n) { emit(0x0400 | (n&255)); }
    void mask(unsigned n) { emit(0x0500 | n); }
    void cmp(unsigned n) { emit(0x0800 | n); }
    void ix(unsigned n) { emit(0x0900 | n); }
    void op(unsigned n) { emit(0x0e00 | n); }
    void ret() { emit(0xf200); }
    void crc_seed(unsigned n) { ldi(n&255); op(0x11); ldi(n>>8); op(0x12); }
    void crc_poly(unsigned n) { ldi(n&255); op(0x13); ldi(n>>8); op(0x14); }
    void handshake(unsigned pid) { set(90,96); set(97,pid); set(37,2); call("transmit"); }
    void finish(const string &hex, const string &listing) {
        for (auto r:refs) {
            auto it=labels.find(r.name); if(it==labels.end()) throw runtime_error("missing " + r.name);
            if ((r.op==0xf400 && it->second>=1024) || it->second>=2048) throw runtime_error("target out of range " + r.name);
            words[r.at]=r.op|it->second;
        }
        if(words.size()>2048) throw runtime_error("program exceeds 2048 words");
        ofstream h(hex), l(listing); if(!h||!l) throw runtime_error("cannot open output");
        for(unsigned i=0;i<2048;i++) h<<std::hex<<setfill('0')<<setw(4)<<(i<words.size()?words[i]:0)<<'\n';
        for(unsigned i=0;i<words.size();i++) {
            for(auto label:labels) if(label.second==i) l<<label.first<<":\n";
            l<<std::hex<<setfill('0')<<setw(4)<<i<<"  "<<setw(4)<<words[i]<<'\n';
        }
        cout<<"USB experimental image: "<<dec<<words.size()<<" / 2048 words\n";
    }
};
// Scratch layout: RX[0..12] includes SYNC/PID; TX[16..29] includes SYNC/PID.
enum { ADDRESS=32, CONFIG, TOKEN, ENDPOINT, CONTROL, TXLEN, RXLEN, LAST_TX,
       CTRL_PID, EP_PID, PTR, REMAIN, CHUNK, NEW_ADDR, NEW_CONFIG, IDLE, PROTOCOL,
       LEDS, KEY, ACKED_KEY, EP_PENDING, OUT_ACCEPTED, PID, TEMP, CTRL_PENDING,
       NEED_ZLP, EP_KEY, IDLE_STAMP, IDLE_TICKS };
// CONTROL: 0 idle, 1 control-IN data, 2 status-IN, 3 status-OUT,
//          4 SET_REPORT output data, 5 STALL.
int main(int argc,char **argv) try {
    if(argc!=3 && argc!=5) throw runtime_error("usage: build_usb_firmware OUTPUT.hex OUTPUT.lst [VID PID] (IDs decimal or 0x-prefixed)");
    unsigned vid=0xffff, pid=0xffff;
    if(argc==5) {
        vid=stoul(argv[3],nullptr,0); pid=stoul(argv[4],nullptr,0);
        if(vid==0 || vid>=0xffff || pid>0xffff) throw runtime_error("invalid device identifiers");
    }
    Image a; a.j("initialize");
    // RECEIVE: no nested calls. RXLEN=FF reports a long SE0 reset; 0 means bad
    // framing/keepalive. All other lengths include SYNC and PID.
    a.label("receive"); a.emit(0x3000); a.set(RXLEN,0); a.ix(0);
    a.op(0x23);
    a.ldi(0); a.op(0x19); a.emit(0xfc06); a.emit(0x0d21); a.emit(0xfd80); a.op(0x0e);
    a.label("idle"); a.op(0x00); a.mask(3); a.cmp(1); a.eq("sop");
    a.cmp(0); a.ne("idle"); a.emit(0x8064);
    a.label("reset_wait"); a.op(0x00); a.mask(3); a.ne("idle"); a.ref(0x9000,"reset_wait");
    a.op(0x10); a.set(RXLEN,255); a.ret();
    a.label("sop"); a.op(0x1c);
    a.label("rx_bit"); a.op(0x0f); a.mask(3); a.eq("eop");
    a.cmp(3); a.eq("rx_bad"); a.op(0x0b);
    a.emit(0x0f07); a.j("rx_bad"); // bad stuffed bit
    a.emit(0x0f05); a.j("rx_byte"); a.j("rx_bit");
    a.label("rx_byte"); a.op(0x03); a.emit(0x0b00); a.op(0x15); a.emit(0x0c01); a.op(0x0a);
    a.op(0x06); a.cmp(2); a.ne("rx_bounds"); a.ld(1); a.mask(2); a.eq("rx_token_crc");
    a.op(0x23); a.j("rx_bounds"); a.label("rx_token_crc"); a.op(0x22);
    a.label("rx_bounds"); a.op(0x06); a.cmp(13); a.lt("rx_bit"); a.j("rx_bad");
    a.label("eop"); a.op(0x1e); a.ne("rx_bad");
    a.emit(0x0f09); a.j("rx_bad"); // missing mandatory trailing stuffed zero
    a.emit(0x0f0b); a.j("rx_bad"); // sample servicing overrun
    a.op(0x0f); a.mask(3); a.ne("rx_bad"); // second SE0 cell
    a.emit(0x8010);
    a.label("eop_j"); a.op(0); a.mask(3); a.ne("eop_nonzero");
    a.ref(0x9000,"eop_j"); a.j("rx_bad");
    a.label("eop_nonzero");
    a.cmp(2); a.ne("rx_bad"); // return at J edge, leaving inter-packet processing time
    a.op(0x10); a.op(0x06); a.st(RXLEN); a.ret();
    a.label("rx_bad"); a.op(0x10); a.set(RXLEN,0); a.ret();

    // TRANSMIT: fully programmable NRZI/stuffing assists, no USB packet FSM.
    // Buffer includes SYNC. One execution context, 33 clocks per bit at 50MHz.
    a.label("transmit"); a.emit(0x1002); a.emit(0x3003); a.emit(0xfb03); a.emit(0xfc06);
    a.emit(0xfd00); a.emit(0x0d21); a.op(0x1a); a.op(0x0e); a.ld(90); a.op(5);
    a.ld(TXLEN); a.st(TEMP);
    a.label("tx_byte"); a.emit(0x0a00); a.op(0x04);
    a.label("tx_bit"); a.op(0x0f); a.op(0x0c); a.emit(0x0f04); a.j("tx_bit");
    a.emit(0x0c01); a.ld(TEMP); a.add(255); a.st(TEMP); a.ne("tx_byte");
    // A final run of six ones needs a stuffed zero BEFORE EOP.
    a.emit(0x0f09); a.j("tx_final_stuff"); a.j("tx_eop");
    a.label("tx_final_stuff"); a.op(0x0f); a.op(0x0c);
    a.label("tx_eop"); a.op(0x0f); a.emit(0x1000); a.op(0x0f); a.op(0x0f);
    a.emit(0x1002); a.op(0x0f); a.emit(0x3000); a.op(0x10); a.ret();

    // CRC helper for a prepared data packet: CHUNK bytes at scratch[18..].
    a.label("append_crc"); a.op(0x23); a.ld(90); a.add(2); a.op(5);
    a.ld(CHUNK); a.eq("crc_end"); a.op(0x1d);
    a.label("crc_loop"); a.emit(0x0a00); a.op(0x15); a.emit(0x0c01); a.ref(0x9000,"crc_loop");
    a.label("crc_end"); a.op(0x16); a.op(0x07); a.emit(0x0b00); a.emit(0x0c01);
    a.op(0x17); a.op(0x07); a.emit(0x0b00); a.ld(CHUNK); a.add(4); a.st(TXLEN); a.ret();

    a.label("initialize");
    a.crc_poly(0x14); a.crc_seed(0x1f); a.op(0x20);
    a.crc_poly(0xa001); a.crc_seed(0xffff); a.op(0x21);
    // Simulation-only identifiers FFFF:FFFF: replace with legitimately usable
    // VID/PID before attachment to a physical host. No third-party VID borrowed.
    vector<unsigned> device={18,1,0x10,1,0,0,0,8,vid&255,vid>>8,pid&255,pid>>8,0,1,0,0,0,1};
    vector<unsigned> report={0x05,1,0x09,6,0xa1,1,0x05,7,0x19,0xe0,0x29,0xe7,
        0x15,0,0x25,1,0x75,1,0x95,8,0x81,2,0x95,1,0x75,8,0x81,1,
        0x95,5,0x75,1,0x05,8,0x19,1,0x29,5,0x91,2,0x95,1,0x75,3,0x91,1,
        0x95,6,0x75,8,0x15,0,0x25,0x65,0x05,7,0x19,0,0x29,0x65,0x81,0,0xc0};
    vector<unsigned> config={9,2,34,0,1,1,0,0xc0,0,9,4,0,0,1,3,1,1,0,
        9,0x21,0x11,1,0,1,0x22,unsigned(report.size()),0,7,5,0x81,3,8,0,10};
    unsigned d=128; for(auto b:device) a.set(d++,b);
    d=146; for(auto b:config) a.set(d++,b);
    d=180; for(auto b:report) a.set(d++,b);
    a.set(16,0x80); a.set(64,0x80); a.set(96,0x80);
    // The demo has exactly two reports. Precompute their payload CRCs as
    // firmware data; the general CRC datapath handles dynamic control traffic.
    for(unsigned base : {64u,100u}) {
        a.set(base,0x80);
        uint16_t crc=0xffff;
        for(unsigned b=0;b<8;b++) {
            unsigned value=(base==64 && b==2)?4:0; a.set(base+2+b,value);
            for(unsigned bit=0;bit<8;bit++) crc=(crc>>1)^(((crc^(value>>bit))&1)?0xa001:0);
        }
        crc=~crc; a.set(base+10,crc&255); a.set(base+11,crc>>8);
    }
    a.label("bus_reset");
    for(unsigned n=ADDRESS;n<=IDLE_TICKS;n++) a.set(n,0);
    a.set(NEW_ADDR,255); a.set(NEW_CONFIG,255); a.set(CTRL_PID,0x4b); a.set(EP_PID,0xc3); a.set(PROTOCOL,1);
    a.ldi(0); a.op(0x32); a.op(0x33); a.op(0x34);
    a.ldi(0); a.op(0x18);
    a.label("main"); a.call("receive");
    a.ld(RXLEN); a.cmp(2); a.ne("not_ack");
    a.ld(0); a.cmp(0x80); a.ne("main");
    a.ld(1); a.cmp(0xd2); a.eq("acked_fast"); a.j("main");
    a.label("not_ack");
    // SETUP/OUT tokens are immediately followed by DATA at a two-bit gap.
    // Save their checked token fields now; defer address/endpoint filtering
    // until DATA arrives so the sampler is re-armed before its SYNC edge.
    a.ld(RXLEN); a.cmp(4); a.ne("normal_packet");
    a.ld(1); a.cmp(0x2d); a.eq("out_token_fast"); a.cmp(0xe1); a.eq("out_token_fast");
    a.label("normal_packet"); a.ld(RXLEN); a.cmp(255); a.eq("bus_reset"); a.cmp(2); a.lt("main");
    a.ld(0); a.cmp(0x80); a.ne("main"); a.ld(1); a.st(PID);
    a.cmp(0xd2); a.eq("acked");
    // A non-ACK cannot acknowledge the preceding device packet.
    a.set(LAST_TX,0); a.ld(PID); a.cmp(0xc3); a.eq("data_packet"); a.cmp(0x4b); a.eq("data_packet");
    a.set(TOKEN,0); a.ld(RXLEN); a.cmp(4); a.ne("main");
    a.ld(PID); a.cmp(0x2d); a.eq("token_packet"); a.cmp(0xe1); a.eq("token_packet"); a.cmp(0x69); a.ne("main");
    a.label("token_packet");
    a.op(0x16); a.cmp(6); a.ne("main");
    a.ld(2); a.mask(0x7f); a.emit(0xfa00|ADDRESS); a.ne("main");
    a.ld(2); a.op(0x47); a.st(TEMP);
    a.ld(3); a.mask(7); a.op(0x09); a.emit(0xf900|TEMP); a.st(ENDPOINT);
    a.ld(PID); a.st(TOKEN); a.cmp(0x69); a.eq("in_token"); a.j("main");

    a.label("out_token_fast"); a.set(TOKEN,0); a.set(LAST_TX,0);
    a.ld(0); a.cmp(0x80); a.ne("main"); a.op(0x16); a.cmp(6); a.ne("main");
    a.ld(2); a.st(93); a.ld(3); a.st(94); a.ld(1); a.st(TOKEN); a.j("main");

    a.label("data_packet"); a.ld(RXLEN); a.cmp(4); a.lt("main");
    a.op(0x16); a.cmp(1); a.ne("main"); a.op(0x17); a.cmp(0xb0); a.ne("main");
    a.ld(93); a.mask(0x7f); a.emit(0xfa00|ADDRESS); a.ne("main");
    a.ld(93); a.mask(0x80); a.ne("main"); a.ld(94); a.mask(7); a.ne("main");
    a.ld(TOKEN); a.cmp(0x2d); a.eq("setup"); a.cmp(0xe1); a.ne("main");
    a.ld(CONTROL); a.cmp(3); a.eq("status_out"); a.cmp(4); a.eq("report_out");
    a.ld(OUT_ACCEPTED); a.eq("stall"); a.emit(0xfa00|RXLEN); a.ne("stall");
    a.ld(PID); a.cmp(0x4b); a.eq("ack_out"); a.j("main");
    a.label("status_out"); a.ld(RXLEN); a.cmp(4); a.ne("stall"); a.ld(PID); a.cmp(0x4b); a.ne("main");
    a.set(CONTROL,0); a.set(OUT_ACCEPTED,4); a.j("ack_out");
    a.label("report_out"); a.ld(RXLEN); a.cmp(5); a.ne("stall"); a.ld(PID); a.cmp(0x4b); a.ne("main");
    a.ld(2); a.st(LEDS); a.set(CONTROL,2); a.set(OUT_ACCEPTED,5);
    a.label("ack_out"); a.set(TOKEN,0); a.handshake(0xd2); a.j("main");

    a.label("setup"); a.ld(RXLEN); a.cmp(12); a.ne("main"); a.ld(PID); a.cmp(0xc3); a.ne("main");
    a.set(TOKEN,0); a.set(CONTROL,5); a.set(CTRL_PENDING,0); a.set(OUT_ACCEPTED,0);
    a.set(NEED_ZLP,0); a.set(NEW_ADDR,255); a.set(NEW_CONFIG,255); a.set(CTRL_PID,0x4b);
    // Parse before ACK, inside the response budget. Parsing after ACK can miss
    // the host's next token at a legal minimum two-bit inter-packet gap.
    a.label("setup_dispatch");
    a.ld(2); a.cmp(0x80); a.eq("standard_in"); a.cmp(0x81); a.eq("interface_in");
    a.cmp(0); a.eq("standard_out"); a.cmp(0x21); a.eq("class_out"); a.cmp(0xa1); a.eq("class_in"); a.j("setup_done");
    a.label("standard_in"); a.ld(3); a.cmp(6); a.eq("descriptor"); a.cmp(8); a.eq("get_config"); a.cmp(0); a.eq("get_status"); a.j("setup_done");
    a.label("interface_in"); a.ld(6); a.ne("setup_done"); a.ld(7); a.ne("setup_done");
    a.ld(3); a.cmp(6); a.eq("descriptor"); a.cmp(10); a.eq("get_interface"); a.cmp(0); a.eq("get_status"); a.j("setup_done");
    a.label("descriptor"); a.ld(4); a.ne("setup_done"); a.ld(5); a.cmp(1); a.eq("device_desc");
    a.cmp(2); a.eq("config_desc"); a.cmp(0x21); a.eq("hid_desc"); a.cmp(0x22); a.eq("report_desc"); a.j("setup_done");
    a.label("device_desc"); a.set(PTR,128); a.set(REMAIN,18); a.j("clamp");
    a.label("config_desc"); a.set(PTR,146); a.set(REMAIN,34); a.j("clamp");
    a.label("hid_desc"); a.set(PTR,164); a.set(REMAIN,9); a.j("clamp");
    a.label("report_desc"); a.set(PTR,180); a.set(REMAIN,report.size()); a.j("clamp");
    a.label("get_config"); a.ld(CONFIG); a.st(80); a.set(PTR,80); a.set(REMAIN,1); a.j("clamp");
    a.label("get_interface"); a.set(80,0); a.set(PTR,80); a.set(REMAIN,1); a.j("clamp");
    a.label("get_status"); a.set(80,0); a.ld(2); a.cmp(0x80); a.ne("status_interface"); a.set(80,1);
    a.label("status_interface"); a.set(81,0); a.set(PTR,80); a.set(REMAIN,2); a.j("clamp");
    a.label("clamp"); a.ld(9); a.ne("descriptor_long"); a.ld(8); a.emit(0xfa00|REMAIN); a.lt("use_wlength"); a.eq("data_ready");
    a.label("descriptor_long"); a.ld(REMAIN); a.mask(7); a.ne("data_ready"); a.set(NEED_ZLP,1); a.j("data_ready");
    a.label("use_wlength"); a.st(REMAIN);
    a.label("data_ready"); a.set(CONTROL,1); a.ld(REMAIN); a.ne("setup_done"); a.set(CONTROL,3); a.j("setup_done");

    a.label("standard_out"); a.ld(5); a.ne("setup_done"); a.ld(6); a.ne("setup_done"); a.ld(7); a.ne("setup_done"); a.ld(8); a.ne("setup_done"); a.ld(9); a.ne("setup_done");
    a.ld(3); a.cmp(5); a.eq("set_address"); a.cmp(9); a.eq("set_config"); a.j("setup_done");
    a.label("set_address"); a.ld(4); a.cmp(128); a.lt("address_valid"); a.j("setup_done");
    a.label("address_valid"); a.st(NEW_ADDR); a.set(CONTROL,2); a.j("setup_done");
    a.label("set_config"); a.ld(4); a.cmp(2); a.lt("config_valid"); a.j("setup_done");
    a.label("config_valid"); a.st(NEW_CONFIG); a.set(CONTROL,2); a.j("setup_done");

    a.label("class_out"); a.ld(6); a.ne("setup_done"); a.ld(7); a.ne("setup_done");
    a.ld(3); a.cmp(0x0a); a.eq("set_idle"); a.cmp(0x0b); a.eq("set_protocol"); a.cmp(9); a.eq("set_report"); a.j("setup_done");
    a.label("set_idle"); a.ld(4); a.ne("setup_done"); a.ld(8); a.ne("setup_done"); a.ld(9); a.ne("setup_done");
    a.ld(5); a.st(IDLE); for(int i=0;i<6;i++) a.op(8); a.op(0x33);
    a.ld(IDLE); a.op(9); a.op(9); a.op(0x32); a.op(0x34); a.set(CONTROL,2); a.j("setup_done");
    a.label("set_protocol"); a.ld(4); a.cmp(2); a.lt("protocol_valid"); a.j("setup_done");
    a.label("protocol_valid"); a.st(PROTOCOL); a.set(CONTROL,2); a.j("setup_done");
    a.label("set_report"); a.ld(4); a.ne("setup_done"); a.ld(5); a.cmp(2); a.ne("setup_done"); a.ld(8); a.cmp(1); a.ne("setup_done");
    a.ld(9); a.ne("setup_done"); a.set(CONTROL,4); a.j("setup_done");
    a.label("class_in"); a.ld(6); a.ne("setup_done"); a.ld(7); a.ne("setup_done"); a.ld(3);
    a.cmp(2); a.eq("get_idle"); a.cmp(3); a.eq("get_protocol"); a.cmp(1); a.eq("get_report"); a.j("setup_done");
    a.label("get_idle"); a.ld(IDLE); a.st(80); a.set(PTR,80); a.set(REMAIN,1); a.j("clamp");
    a.label("get_protocol"); a.ld(PROTOCOL); a.st(80); a.set(PTR,80); a.set(REMAIN,1); a.j("clamp");
    a.label("get_report");
    for(unsigned n=80;n<88;n++) a.set(n,0);
    a.op(0); a.mask(0x80); a.eq("get_report_zero"); a.set(82,4);
    a.label("get_report_zero"); a.set(PTR,80); a.set(REMAIN,8); a.j("clamp");
    a.label("setup_done"); a.handshake(0xd2); a.j("main");

    a.label("in_token"); a.set(TOKEN,0); a.ld(ENDPOINT); a.eq("ep0_in"); a.cmp(1); a.ne("main");
    a.ld(CONFIG); a.eq("main"); a.j("ep1_in");
    a.label("ep0_in"); a.ld(CONTROL); a.cmp(5); a.eq("stall"); a.cmp(2); a.eq("status_in"); a.cmp(1); a.ne("nak");
    a.ld(CTRL_PENDING); a.ne("ctrl_send"); a.ld(REMAIN); a.cmp(8); a.lt("short_chunk"); a.ldi(8);
    a.label("short_chunk"); a.st(CHUNK); a.st(62);
    a.op(0x23); a.ld(PTR); a.op(5);
    a.ld(CHUNK); a.eq("ctrl_crc"); a.op(0x1d);
    for(unsigned b=0;b<8;b++) {
        a.label("copy_descriptor_"+to_string(b)); a.emit(0xfe00| (18+b));
        if(b<7) { a.ref(0x9000,"copy_descriptor_"+to_string(b+1)); a.j("ctrl_crc"); }
    }
    a.label("ctrl_crc");
    a.ld(CHUNK); a.add(18); a.op(5); a.op(0x16); a.op(7); a.emit(0x0b00); a.emit(0x0c01);
    a.op(0x17); a.op(7); a.emit(0x0b00); a.ld(CHUNK); a.add(4); a.st(TXLEN);
    a.ld(CTRL_PID); a.st(17); a.ld(TXLEN); a.st(89); a.set(CTRL_PENDING,1);
    a.label("ctrl_send"); a.set(90,16); a.ld(89); a.st(TXLEN); a.set(LAST_TX,1); a.call("transmit"); a.j("main");
    a.label("status_in"); a.set(90,16); a.set(CHUNK,0); a.set(17,0x4b); a.call("append_crc"); a.set(LAST_TX,3); a.call("transmit"); a.j("main");
    a.label("ep1_in");
    a.ld(EP_PENDING); a.ne("ep1_prepare"); a.op(0); a.mask(0x80); a.st(KEY);
    a.emit(0xfa00|ACKED_KEY); a.ne("ep1_new"); a.emit(0x0f0d); a.j("ep1_new"); a.j("nak");
    a.label("ep1_new"); a.ld(KEY); a.st(EP_KEY); a.set(EP_PENDING,1);
    a.label("ep1_prepare"); a.ld(EP_KEY); a.eq("ep1_zero"); a.set(90,64); a.j("ep1_ready");
    a.label("ep1_zero"); a.set(90,100);
    a.label("ep1_ready"); a.ld(90); a.add(1); a.op(5); a.ld(EP_PID); a.emit(0x0b00);
    a.set(TXLEN,12); a.set(LAST_TX,2); a.call("transmit"); a.j("main");
    a.label("nak"); a.handshake(0x5a); a.j("main");
    a.label("stall"); a.handshake(0x1e); a.j("main");

    a.label("acked"); a.ld(RXLEN); a.cmp(2); a.ne("main");
    a.label("acked_fast"); a.ld(LAST_TX); a.st(TEMP); a.set(LAST_TX,0);
    a.ld(TEMP); a.cmp(1); a.eq("ctrl_ack"); a.cmp(2); a.eq("ep1_ack"); a.cmp(3); a.ne("main");
    a.ld(NEW_ADDR); a.cmp(255); a.eq("commit_config"); a.st(ADDRESS); a.set(NEW_ADDR,255);
    a.label("commit_config"); a.ld(NEW_CONFIG); a.cmp(255); a.eq("status_committed"); a.st(CONFIG); a.op(0x18);
    a.set(NEW_CONFIG,255); a.set(EP_PID,0xc3); a.set(EP_PENDING,0); a.set(ACKED_KEY,0);
    a.label("status_committed"); a.set(CONTROL,0); a.j("main");
    a.label("ep1_ack"); a.op(0x34); a.ld(EP_KEY); a.st(ACKED_KEY); a.set(EP_PENDING,0); a.ld(EP_PID); a.emit(0x0688); a.st(EP_PID); a.j("main");
    a.label("ctrl_ack"); a.ld(62); a.st(CHUNK); a.set(CTRL_PENDING,0); a.ld(CTRL_PID); a.emit(0x0688); a.st(CTRL_PID);
    a.ld(PTR); a.emit(0xf900|CHUNK); a.st(PTR);
    a.ld(CHUNK); a.op(7); a.add(1); a.emit(0xf900|REMAIN); a.st(REMAIN); a.ne("main");
    a.ld(CHUNK); a.eq("ctrl_finished"); a.ld(NEED_ZLP); a.eq("ctrl_finished"); a.set(NEED_ZLP,0); a.j("main");
    a.label("ctrl_finished"); a.set(CONTROL,3); a.j("main");
    a.finish(argv[1],argv[2]); return 0;
} catch(const exception &e) { cerr<<e.what()<<'\n'; return 1; }
