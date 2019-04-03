module pcecd_top(
	input            reset,
	input            clk,
	// cpu register interface
	input            sel,
	input  [7:0]     addr,
	input            wr,
	input            rd,
	output reg [7:0] dout,
	input      [7:0] din,
	output           irq2_assert,
	
	output reg [7:0] command_byte	// Debug
);

//TODO: add hps "channel" to read/write from save ram

reg [7:0] cd_command_buffer [0:15];
reg [3:0] cd_command_buffer_pos = 0;

//wire [7:0] gp_ram_do,adpcm_ram_do,save_ram_do;

//- 64K general purpose RAM for the CD software to use
// generic_spram #(16,8) gp_ram(
// 	.clk(clk),
// 	.rst(reset),
// 	.ce(1'b1),
// 	.we(),
// 	.oe(1'b1),
// 	.addr(),
// 	.di(din),
// 	.dout(gp_ram_do)
// );

//- 64K ADPCM RAM for sample storage
// generic_spram #(16,8) adpcm_ram(
// 	.clk(clk),
// 	.rst(reset),
// 	.ce(1'b1),
// 	.we(),
// 	.oe(1'b1),
// 	.addr(),
// 	.di(din),
// 	.dout(adpcm_ram_do)
// );

 //- 2K battery backed RAM for save game data and high scores
// generic_tpram #(11,8) save_ram(
// 	.clk_a(clk),
// 	.rst_a(reset),
// 	.ce_a(1'b1),
// 	.we_a(),
// 	.oe_a(1'b1),
// 	.addr_a(),
// 	.di_a(din),
// 	.do_a(save_ram_do),
// 	.clk_b(clk),
// 	.rst_b(reset),
// 	.ce_b(1'b1),
// 	.we_b(),
// 	.oe_b(1'b1),
// 	.addr_b(),
// 	.di_b(),
// 	.do_b()
// );

//TODO: check if registers are needed (things are probably bound to some logic with the cd drive), placeholders for now
wire [7:0] cdc_status = {SCSI_BSY, SCSI_REQ, SCSI_MSG, SCSI_CD, SCSI_IO, SCSI_BIT2, SCSI_BIT1, SCSI_BIT0};             // $1800 - CDC status

// CD Interface Register 0x00 - CDC status
	// x--- ---- busy signal
	// -x-- ---- request signal
	// --x- ---- msg bit
	// ---x ---- cd signal
	// ---- x--- i/o signal

// Signals under our (the "target") control.
/*
wire SCSI_BSY = cdc_status[7];
wire SCSI_REQ = cdc_status[6];
wire SCSI_MSG = cdc_status[5];
wire SCSI_CD = cdc_status[4];
wire SCSI_IO = cdc_status[3];
*/

// Signals under the control of the initiator (not us!)
/*
wire RST_signal = SCSI_RST;
wire ACK_signal = SCSI_ACK;
wire SEL_signal = SCSI_SEL;
*/

localparam BUSY_BIT = 8'h80;
localparam REQ_BIT  = 8'h40;
localparam MSG_BIT  = 8'h20;
localparam CD_BIT   = 8'h10;
localparam IO_BIT   = 8'h08;

localparam PHASE_BUS_FREE    = 8'b00000001;
localparam PHASE_COMMAND     = 8'b00000010;
localparam PHASE_DATA_IN     = 8'b00000100;
localparam PHASE_DATA_OUT    = 8'b00001000;
localparam PHASE_STATUS      = 8'b00010000;
localparam PHASE_MESSAGE_IN  = 8'b00100000;
localparam PHASE_MESSAGE_OUT = 8'b01000000;

reg [7:0] cdc_databus;            // $1801 - CDC command / status / data //TODO: this will probably change to a wire connected to the pcecd_drive module
reg [7:0] adpcm_control;          // $1802 - ADPCM / CD control
reg [7:0] bram_lock;              // $1803 - BRAM lock / CD status
reg bram_enabled;
reg [7:0] cd_reset;               // $1804 - CD reset
reg [7:0] convert_pcm;            // $1805 - Convert PCM data / PCM data
reg [7:0] pcm_data;               // $1806 - PCM data
reg [7:0] bram_unlock;            // $1807 - BRAM unlock / CD status
reg [7:0] adpcm_address_low;      // $1808 - ADPCM address (LSB) / CD data
reg [7:0] adpcm_address_high;     // $1809 - ADPCM address (MSB)
reg [7:0] adpcm_ram_data;         // $180A - ADPCM RAM data port
reg [7:0] adpcm_dma_control;      // $180B - ADPCM DMA control
reg [7:0] adpcm_status;           // $180C - ADPCM status
reg [7:0] adpcm_address_control;  // $180D - ADPCM address control
reg [7:0] adpcm_playback_rate;    // $180E - ADPCM playback rate
reg [7:0] adpcm_fade_timer;       // $180F - ADPCM and CD audio fade timer

// Phase handling
reg [7:0] phase = PHASE_BUS_FREE;
//reg bus_phase_changed = 1;

reg [7:0] old_phase;

// Status sending
reg cd_status_sent = 0;
reg cd_message_sent = 0;


// Ack handling
reg clear_ack = 0;

// SCSI Command Handling
reg SCSI_think = 0;
reg SCSI_RST = 0;
reg SCSI_ACK = 0;
// @todo SCSI device selected is forced to one here
reg SCSI_SEL = 1;
reg SCSI_SEL_flipflop = 0;
reg SCSI_SEL_flipflop_latch = 0;

reg SCSI_BSY;
reg SCSI_REQ;
reg SCSI_MSG;
reg SCSI_CD;
reg SCSI_IO;
reg SCSI_BIT2;
reg SCSI_BIT1;
reg SCSI_BIT0;
// ^ Bits [2:0] are probably drive SCSI ID bits.
// The PCE often writes 0x81 (b10000001) to both CDC_STAT and CDC_CMD.
//
// I think it's quite possible that whenever CDC_STAT gets written, that IS the whole SCSI ID
// (of both the PCE (7) and CD drive (0).
//
// (from Io_cd13.PDF)...
//
// "Selection: In this state, the initiator selects a target unit and gets the target to carry out a given function,
// such as reading or writing data. The initator outputs the OR-value of its SCSI-ID and the target's SCSI-ID onto the DATA bus
// (for example, if the initiator is 2 (0000 0100) and the target is 5 (0010 0000) then the OR-ed ID on the bus wil be 0010 0100.)
// The target then determines that it's ID is on the data bus, and sets the BUSY line active."
// 
//
// In short, we can ignore that, and assume that one CD drive is on the bus.
// It looks like the PCE maybe writes the the value 0x81 to both CDC_STAT and CDC_CMD as a kind of double-check.
// And the CD drive ignores that "Command" anyway, since it's not in SELection at that point.
//
// Which is why MAME, bizhawk, and other emulators don't need to have the 0x81 in command parsing table.
// Those emulators just set the SCSI_SEL bit whenever CDC_STAT gets written to (and they also clear the CD transfer IRQ flags).
//

reg [3:0] packet_bytecount;

//TODO: a pcecd_drive module should be probably added
always_ff @(posedge clk) begin
	if (reset) begin
		//cdc_status            <= 8'b0;
		SCSI_BSY  <= 1'b0;
		SCSI_REQ  <= 1'b0;
		SCSI_MSG  <= 1'b0;
		SCSI_CD   <= 1'b0;
		SCSI_IO   <= 1'b0;
		SCSI_BIT2 <= 1'b0;
		SCSI_BIT1 <= 1'b0;
		SCSI_BIT0 <= 1'b0;
		
		cdc_databus           <= 8'b0;
		adpcm_control         <= 8'b0;
		bram_lock             <= 8'b0;
		bram_enabled          <= 1'b1;
		cd_reset              <= 8'b0;
		convert_pcm           <= 8'b0;
		pcm_data              <= 8'b0;
		bram_unlock           <= 8'b0;
		adpcm_address_low     <= 8'b0;
		adpcm_address_high    <= 8'b0;
		adpcm_ram_data        <= 8'b0;
		adpcm_dma_control     <= 8'b0;
		adpcm_status          <= 8'b0;
		adpcm_address_control <= 8'b0;
		adpcm_playback_rate   <= 8'b0;
		adpcm_fade_timer      <= 8'b0;
		phase                 <= 8'b0;
		phase         <= PHASE_BUS_FREE; 
		//bus_phase_changed			<= 0;
	end else begin
		old_phase <= phase;
	
		if (SCSI_REQ && SCSI_ACK && phase==PHASE_COMMAND && cd_command_buffer_pos==0) begin
			case (command_byte)
				8'h00: begin	// Command = 0x00 TEST_UNIT_READY (6)
					packet_bytecount <= 6;
				end
				8'h08: begin	// Command = 0x08 READ (6) \n");
					packet_bytecount <= 6;
				end
				8'hD8: begin	// Command = 0xD8 NEC_SET_AUDIO_START_POS (10) \n");
					packet_bytecount <= 10;
				end
				8'hD9: begin	// Command = 0xD9 NEC_SET_AUDIO_STOP_POS (10) \n");
					packet_bytecount <= 10;
				end
				8'hDA: begin	// Command = 0xDA NEC_PAUSE (10) \n");
					packet_bytecount <= 10;
				end
				8'hDD: begin	// Command = 0xDD NEC_GET_SUBQ (10) \n");
					packet_bytecount <= 10;
				end
				8'hDE: begin	// Command = 0xDE NEC_GET_DIR_INFO (10) \n");
					packet_bytecount <= 10;
				end
				8'hFF: begin	// Command = 0xFF END_OF_LIST (1) \n");
					packet_bytecount <= 1;
				end
				8'h81: begin	// Command = 0x81 RESET CMD BUFFER (1), maybe? \n");
					packet_bytecount <= 1;
				end
			endcase
		end
	
		//if (sel) begin
		begin
			SCSI_think <= 0;
			if (sel & rd) begin
				case (addr)
					// Super System Card registers $18Cx range
					8'hC1: dout <= 8'haa;
					8'hC2: dout <= 8'h55;
					8'hC3: dout <= 8'h00;
					8'hC5: dout <= 8'haa;
					8'hC6: dout <= 8'h55;
					8'hC7: dout <= 8'h03;

					8'h00: begin	// 0x1800 CDC_STAT
						dout <= cdc_status;
						$display("Read 0x0. dout = 0x%h", cdc_status);
					end
					8'h01: begin	// 0x1801 CDC_CMD
						dout <= cdc_databus;
					end
					8'h02: begin	// 0x1802 INT_MASK
						$display("Read 0x2. dout = 0x%h", adpcm_control);
						dout <= adpcm_control;
					end
					8'h03: begin	// 0x1803 BRAM_LOCK
						$display("Read 0x3. dout = 0x%h", bram_lock);
						dout <= bram_lock;
						bram_lock <= bram_lock ^ 2;
						$display("bram_enabled = 0x%h", 1'b0);
						bram_enabled <= 1'b0;
					end
					8'h04: begin	// 0x1804 CD_RESET
						$display("Read 0x4. dout = 0x%h", cd_reset);
						dout <= cd_reset;
					end
					8'h05: begin
						dout <= convert_pcm;
					end
					8'h06: begin
						dout <= pcm_data;
					end
					8'h07: begin
						dout <= bram_unlock;
					end
					8'h08: begin
						dout <= adpcm_address_low;
					end
					8'h09: begin
						dout <= adpcm_address_high;
					end
					8'h0A: begin
						dout <= adpcm_ram_data;
					end
					8'h0B: begin
						dout <= adpcm_dma_control;
					end
					8'h0C: begin
						dout <= adpcm_status;
					end
					8'h0D: begin
						dout <= adpcm_address_control;
					end
					8'h0E: begin
						dout <= adpcm_playback_rate;
					end
					8'h0F: begin
						dout <= adpcm_fade_timer;
					end
					default: dout <= 8'hFF;
				endcase
			end else if (sel & wr) begin
				case (addr)
					8'h00: begin	// 0x1800 CDC_STAT
						//cdc_status <= din;
						//SCSI_BSY  <= din[7];
						//SCSI_REQ  <= din[6];
						//SCSI_MSG  <= din[5];
						//SCSI_CD   <= din[4];
						//SCSI_IO   <= din[3];
						SCSI_BIT2 <= din[2];
						SCSI_BIT1 <= din[1];
						SCSI_BIT0 <= din[0];
						
						// Try to trigger the SEL flipflop latch thing
						SCSI_SEL_flipflop_latch <= 1;
					end
					8'h01: begin	// 0x1801 CDC_CMD
						//$display("Write to 0x1. 0x%h", din);
						cdc_databus <= din;
						SCSI_think <= 1;
					end
					8'h02: begin	// 0x1802 INT_MASK
						adpcm_control <= din;
						// Set ACK signal to contents of the interrupt registers 7th bit? A full command will have this bit high
						SCSI_ACK <= din[7];
						SCSI_think <= 1;
						irq2_assert <= (din & bram_lock & 8'h7C) != 0; // RefreshIRQ2(); ... using din here
						//$display("Write to 0x2. irq2_assert will be: 0x%h", (adpcm_control & bram_lock & 8'h7C) != 0);
					end
					8'h03: begin	// 0x1803 BRAM_LOCK
						bram_lock <= din;
					end
					8'h04: begin	// 0x1804 CD_RESET
						cd_reset <= din;
						// Set RST signal to contents of RST registers 2nd bit
						SCSI_RST <= (din & 8'h02) != 0;
						SCSI_think <= 1;
						if ((din & 8'h02) != 0) begin // if (SCSI_RST)
							bram_lock <= bram_lock & 8'h8F; // CdIoPorts[3] &= 0x8F;
							irq2_assert <= (adpcm_control & bram_lock & 8'h7C) != 0; // RefreshIRQ2();
							//$display("Write to 0x4. irq2_assert will be: 0x%h", (adpcm_control & bram_lock & 8'h7C) != 0);
						end
					end
					8'h05: begin	// 0x1805
						convert_pcm <= din;
					end
					8'h06: begin	// 0x1806
						pcm_data <= din;
					end
					8'h07: begin	// 0x1807
						bram_unlock <= din;
					end
					8'h08: begin	// 0x1808
						adpcm_address_low <= din;
					end
					8'h09: begin	// 0x1809
						adpcm_address_high <= din;
					end
					8'h0A: begin	// 0x180A
						adpcm_ram_data <= din;
					end
					8'h0B: begin	// 0x180B
						adpcm_dma_control <= din;
					end
					8'h0C: begin	// 0x180C
						adpcm_status <= din;
					end
					8'h0D: begin	// 0x180D
						adpcm_address_control <= din;
					end
					8'h0E: begin	// 0x180E
						adpcm_playback_rate <= din;
					end
					8'h0F: begin	// 0x180F
						adpcm_fade_timer <= din;
					end
				endcase
			end // end wr

			if (SCSI_SEL_flipflop_latch) begin
				if (SCSI_SEL_flipflop) begin
					$display("**** LATCH LAST ******");
					// This one will get executed last
					SCSI_SEL <= 0;
					SCSI_think <= 1;
					// Reset the flip flop and latch
					SCSI_SEL_flipflop <= 0;
					SCSI_SEL_flipflop_latch <= 0;
				end else begin
					$display("**** LATCH FIRST ******");
					// This one will get executed first
					SCSI_SEL <= 1;
					SCSI_think <= 1;
					SCSI_SEL_flipflop <= 1;
				end
			end // End Scsi flipflop

			if (clear_ack) begin
				$display("PCECD: Clearing ACK");
			end

			if (SCSI_RST) begin
				$display("Performing reset");
				//cdc_status <= 0;
				SCSI_BSY  <= 1'b0;
				SCSI_REQ  <= 1'b0;
				SCSI_MSG  <= 1'b0;
				SCSI_CD   <= 1'b0;
				SCSI_IO   <= 1'b0;
				SCSI_BIT2 <= 1'b0;
				SCSI_BIT1 <= 1'b0;
				SCSI_BIT0 <= 1'b0;
				
				SCSI_ACK <= 0;
				SCSI_RST <= 0;
				// Clear the command buffer
				// Stop all reads
				// Stop all audio
				//phase <= PHASE_BUS_FREE;
				
				phase <= PHASE_COMMAND;	// ElectronAsh.
				cd_command_buffer_pos <= 0;
				
				//bus_phase_changed <= 1;
			end

			if (/*SCSI_think && */!SCSI_RST) begin
				//$display("SCSI_Think()");
				SCSI_think <= 0;

				/*
				if (SCSI_SEL && !(SCSI_BSY)) begin
					phase <= PHASE_COMMAND;
					bus_phase_changed <= 1;
				end
				*/
				
				case (phase)
					PHASE_BUS_FREE: begin
						if (SCSI_SEL) begin
							$display ("PHASE_BUS_FREE");
							//bus_phase_changed <= 1;
							//cdc_status <= cdc_status & ~BUSY_BIT & ~MSG_BIT & ~CD_BIT & ~IO_BIT & ~REQ_BIT;
							SCSI_BSY <= 0;	// Clear BUSY_BIT.
							SCSI_REQ <= 0;	// Clear REQ_BIT.
							SCSI_MSG <= 0;	// Clear MSG_BIT.
							SCSI_CD  <= 0;	// Clear CD_BIT.
							SCSI_IO  <= 0;	// Clear IO_BIT.
							bram_lock <= bram_lock & ~8'h20; // CDIRQ(IRQ_8000, PCECD_Drive_IRQ_DATA_TRANSFER_DONE);
						end
					end
					PHASE_COMMAND: begin	
						$display ("PHASE_COMMAND");
						//cdc_status <= cdc_status | BUSY_BIT | CD_BIT | REQ_BIT & ~IO_BIT & ~MSG_BIT;
						SCSI_BSY <= 1;	// Set BUSY_BIT.
						SCSI_REQ <= 1;	// Set REQ_BIT.
						SCSI_MSG <= 0;	// Clear MSG_BIT.
						SCSI_CD  <= 1;	// Set CD_BIT.
						SCSI_IO  <= 0;	// Clear IO_BIT.
						$display ("SCSI_ACK is %b", SCSI_ACK);
						$display ("SCSI_REQ is %b", SCSI_REQ);
						$display ("cd_command_buffer_pos is %h", cd_command_buffer_pos);
						if (SCSI_REQ && SCSI_ACK) begin	// Databus is valid now, so we need to collect a command
							$display ("phase_command - setting req false and adding command to buffer");
							if (cd_command_buffer_pos==0) command_byte <= cdc_databus;
							cd_command_buffer[cd_command_buffer_pos] <= cdc_databus;
							
							if (cd_command_buffer_pos == packet_bytecount) phase <= PHASE_STATUS;	// TESTING! ElectronAsh.
							else cd_command_buffer_pos <= cd_command_buffer_pos + 1;
							
							// Set the REQ low
							SCSI_REQ <= 0;	// Clear REQ_BIT.
							// @todo sort Ack clearing out as soon as we get an ACK that is!
							//clear_ack <= 0;
						end
						if (!SCSI_REQ && !SCSI_ACK && cd_command_buffer_pos > 4'h0) begin
							// We got a command!!!!!!!
							//$display ("We got a command! $%h",  cd_command_buffer [cd_command_buffer_pos]);
							$display("We got a command!");
							//$finish;
						end
					end
					PHASE_STATUS: begin
						$display ("PHASE_STATUS");
						//cdc_status <= cdc_status | BUSY_BIT | CD_BIT | IO_BIT | REQ_BIT & ~MSG_BIT;
						SCSI_BSY <= 1;	// Set BUSY_BIT.
						SCSI_REQ <= 1;	// Set REQ_BIT.
						SCSI_MSG <= 0;	// Clear MSG_BIT.
						SCSI_CD  <= 1;	// Set CD_BIT.
						SCSI_IO  <= 1;	// Set IO_BIT.
						if (SCSI_REQ && SCSI_ACK) begin
							// Set the REQ low
							//cdc_status[6] <= 0;
							SCSI_REQ <= 0;
							cd_status_sent <= 1;
						end
						if (!SCSI_REQ && !SCSI_ACK && cd_status_sent) begin
							// Status sent, so get ready to send the message!
							cd_status_sent <= 0;
							// @todo message_pending message goes on the buss
							//cd_bus.DB = cd.message_pending;
							phase <= PHASE_MESSAGE_IN;
							//bus_phase_changed <= 1;
						end
					end
					PHASE_DATA_IN: begin
						$display ("PHASE_DATA_IN");
						//cdc_status <= cdc_status | BUSY_BIT | IO_BIT & ~MSG_BIT & ~CD_BIT & ~REQ_BIT;
						SCSI_BSY <= 1;	// Set BUSY_BIT.
						SCSI_REQ <= 0;	// Clear REQ_BIT.
						SCSI_MSG <= 0;	// Clear MSG_BIT.
						SCSI_CD <= 0;	// Clear CD_BIT.
						SCSI_IO <= 1;	// Set IO_BIT.
						//$display ("PHASE_DATA_IN TBC");
						// if (!SCSI_REQ && !SCSI_ACK) {
						// if (din.in_count == 0) // aaand we're done!
						// {
						//     CDIRQCallback(0x8000 | PCECD_Drive_IRQ_DATA_TRANSFER_READY);
						//     if (cd.data_transfer_done) {
						//         SendStatusAndMessage(STATUS_GOOD, 0x00);
						//         cd.data_transfer_done = FALSE;
						//         CDIRQCallback(PCECD_Drive_IRQ_DATA_TRANSFER_DONE);
						//     }
						// } else {
						//     cd_bus.DB = din.ReadByte();
						//     SetREQ(TRUE);
						//}
						// }
						// if (SCSI_REQ && SCSI_ACK) {
						//puts("REQ and ACK true");
						//SetREQ(FALSE);
						// clear_cd_reg_bits(0x00, REQ_BIT);
					end
					PHASE_MESSAGE_IN: begin
						$display ("PHASE_MESSAGE_IN");
						//cdc_status <= cdc_status | BUSY_BIT | MSG_BIT | CD_BIT | IO_BIT | REQ_BIT;
						SCSI_BSY <= 1;	// Set BUSY_BIT. [7]
						SCSI_REQ <= 1;	// Set REQ_BIT. [6]
						SCSI_MSG <= 1;	// Set MSG_BIT. [5]
						SCSI_CD <= 1;	// Set CD_BIT.  [4]
						SCSI_IO <= 1;	// Set IO_BIT.  [3]
						if (SCSI_REQ && SCSI_ACK) begin
							// Set the REQ low
							//cdc_status <= cdc_status & ~REQ_BIT;
							SCSI_REQ <= 0;
							//CDMessageSent <= true;
							cd_message_sent <= 1;
						end
						if (!SCSI_REQ && !SCSI_ACK && cd_message_sent) begin
							//CDMessageSent <= false;
							cd_message_sent <= 0;
							phase <= PHASE_BUS_FREE;
							//bus_phase_changed <= 1;
						end
					end
				endcase
			end // End SCSI_Think();

			
		end // end if sel - and our main logic
	end // end else main
end // end always


endmodule
