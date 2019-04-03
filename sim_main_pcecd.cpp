//docker run --rm -v $(pwd):/data rweda/verilator "cd /data; verilator -Wall --cc pcecd_top.v --exe sim_main_pcecd.cpp; cd obj_dir; make -j -f Vpcecd_top.mk Vpcecd_top"

#include "Vpcecd_top.cpp"
#include "verilated.h"
#include <iostream>

void pcecd_read(char addr, Vpcecd_top* pcecd) {
    pcecd->addr = addr; pcecd->sel = 1; pcecd->rd = 1; pcecd->wr = 0;
}

void pcecd_write(char addr, char din, Vpcecd_top* pcecd) {
    pcecd->addr = addr; pcecd->din = din; pcecd->sel = 1; pcecd->rd = 0; pcecd->wr = 1;
}

// Here we can do specific things on certain clock ticks
void handlePositiveEdgeClock(int tick, Vpcecd_top* pcecd) {
    // This could be something smarter, but for now... we only care about a few clock cycles
    pcecd->sel = 0;
    if (tick == 1) {
        printf("%d) Read from Reg: 0x4  CD_RESET         Expecting: 0x00\n", tick);
        pcecd_read(0x04, pcecd);
    }
    if (tick == 2) {
        printf("%d) Write to Reg:  0x4  CD_RESET         Data: 0x02\n", tick);
        pcecd_write(0x04, 0x02, pcecd);
    }
    if (tick == 3) {
        printf("%d) Read from Reg: 0x4  CD_RESET         Expecting: 0x02\n", tick);
        pcecd_read(0x04, pcecd);
    }
    if (tick == 4) {
        printf("%d) Write to Reg:  0x4  CD_RESET         Data: 0x00\n", tick);
        pcecd_write(0x04, 0x00, pcecd);

    }
    if (tick == 5) {
        printf("%d) Write to Reg:  0x2  INT_MASK         Data: 0x00\n", tick);
        pcecd_write(0x02, 0x00, pcecd);
    }

    // These will need to be sorted out too
    if (tick == 6) {
        printf("%d) Write to Reg:  0xf  ADPCM_FADE       Data: 0x00\n", tick);
    }
    if (tick == 7) {
        printf("%d) Write to Reg:  0xd  ADPCM_ADDR_CONT  Data: 0x80\n", tick);
    }
    if (tick == 8) {
        printf("%d) Write to Reg:  0xd  ADPCM_ADDR_CONT  Data: 0x00\n", tick);
    }
    if (tick == 9) {
        printf("%d) Write to Reg:  0xb  ADPCM_DMA_CONT   Data: 0x00\n", tick);
		pcecd_write(0x01, 0x08, pcecd);		// Testing!! Forcing a READ command.
    }

    if (tick == 10) {
        printf("%d)Read from Reg: 0x2  INT_MASK         Expecting: 0x00\n", tick);
        pcecd_read(0x02, pcecd);
    }
    if (tick == 11) {
        printf("%d)Write to Reg:  0x2  INT_MASK         Data: 0x00\n", tick);
        //pcecd_write(0x02, 0x00, pcecd);
		pcecd_write(0x02, 0x80, pcecd);		// Testing!! Forcing the ACK flag high, to make the drive think that the PCE is sending a command byte.
    }

    // This one too
    if (tick == 12) {
        printf("%d)Write to Reg:  0xe  ADPCM_RATE       Data: 0x00\n", tick);
    }
    if (tick == 13) {
        printf("%d)Read from Reg: 0x3  BRAM_LOCK        Expecting: 0x00\n", tick);
        pcecd_read(0x03, pcecd);
    }
    if (tick == 14) {
        printf("%d)Write to Reg:  0x1  CD_CMD           Data: 0x81\n", tick);
        pcecd_write(0x01, 0x81, pcecd);
    }
    if (tick == 20) {
        printf("%d)Read from Reg: 0x0  CDC_STAT         Expecting: 0x00 <======== This is failing\n", tick);
        pcecd_read(0x00, pcecd);
    }
    if (tick == 21) {
        printf("%d)Write to Reg:  0x0  CDC_STAT         Data: 0x81       Clear the ACK,DONE,BRAM interrupt flags\n", tick);
        pcecd_write(0x00, 0x81, pcecd);
    }
    if (tick == 22) {
        printf("%d)Read from Reg: 0x0  CDC_STAT         Expecting: 0xd1  [7]BUSY [6]REQ  [4]CD\n", tick);
        pcecd_read(0x00, pcecd);
    }
    if (tick == 23) {
        printf("%d)Read from Reg: 0x0  CDC_STAT         Expecting: 0xd1  [7]BUSY [6]REQ  [4]CD\n", tick);
        pcecd_read(0x00, pcecd);
    }

	switch (pcecd->command_byte) {
		case 0x00: printf("Command = 0x00 TEST_UNIT_READY (6) \n"); break;
		case 0x08: printf("Command = 0x08 READ (6) \n"); break;
		case 0xD8: printf("Command = 0xD8 NEC_SET_AUDIO_START_POS \n"); break;
		case 0xD9: printf("Command = 0xD9 NEC_SET_AUDIO_STOP_POS \n"); break;
		case 0xDA: printf("Command = 0xDA NEC_PAUSE \n"); break;
		case 0xDD: printf("Command = 0xDD NEC_GET_SUBQ \n"); break;
		case 0xDE: printf("Command = 0xDE NEC_GET_DIR_INFO \n"); break;
		case 0xFF: printf("Command = 0xFF END_OF_LIST \n"); break;
		case 0x81: printf("Command = 0x81 RESET CMD BUFFER, maybez? \n"); break;
	}
	

    // if (tick == 19) {
    //     printf("%d)Write to Reg: 0x1  CDC_CMD           Data: 0x00\n", tick);
    //     pcecd_write(0x01, 0x00, pcecd);
    // }
    // if (tick == 20) {
    //     printf("%d)Read from Reg: 0x2  INT_MASK         Expecting: 0x00\n", tick);
    //     pcecd_read(0x02, pcecd);
    // }
    // if (tick == 21) {
    //     printf("%d)Write to Reg:  0x2  INT_MASK         Data: 0x80\n", tick);
    //     pcecd_write(0x02, 0x80, pcecd);
    // }
}

int main(int argc, char **argv, char **env) {    
    Verilated::commandArgs(argc, argv);
    // Create instance
    Vpcecd_top* pcecd = new Vpcecd_top;

    // Simulation time...
    int tick = 0;
    while (!Verilated::gotFinish()) {
        tick++;
        //char input;
        //cin>>input;
        // Toggle the clock - tick tock
        pcecd->clk = 0;
        pcecd->eval();
        // tick
        pcecd->clk = 1;
        handlePositiveEdgeClock(tick, pcecd);
        pcecd->eval();
        //logCdRegisters(pcecd);
        // tock
        pcecd->clk = 0;
        pcecd->eval();
    }

    // Done simulating
    pcecd->final();
    // Clean-up
    delete pcecd;
    exit(0);
}
