; udiv24 for Antonia II hardware
;
; m_quot:m_rem = m_prod / m_den
;
antdiv_dd = $fff008
antdiv_ds = antdiv_dd+2
antdiv_qu = antdiv_dd
antdiv_re = antdiv_qu+2
;
	.LONGA OFF
	.LONGI OFF
udiv24_antonia2
	lda m_prod+2
	rep #$20
	.LONGA ON
	jeq ?fast16

	lda m_prod+1
	sta.l antdiv_dd
	lda m_den
	sta.l antdiv_ds
	lda.l antdiv_qu
	sta ?q_hi

	stz ?r_pr+2
	lda m_prod
	and #$00ff
	sta ?r_pr
	lda.l antdiv_re
	sta ?r_pr+1

	cmp #256
	bcc ?hw2

	stz ?q_lo
	stz ?ds32
	stz ?ds32+2

	lda m_den
	sta ?ds32+1

	ldx #$08
?lp8	lsr ?ds32+2
	ror ?ds32
	asl ?q_lo
	lda ?r_pr
	cmp ?ds32
	lda ?r_pr+2
	sbc ?ds32+2
	bcc ?s8

	sta ?r_pr+2
	lda ?r_pr
	sbc ?ds32
	sta ?r_pr

	inc ?q_lo

?s8	dex
	bne ?lp8

	lda ?r_pr
	sta m_rem

	lda ?q_hi
	and #$00ff
	xba
	ora ?q_lo
	sta m_quot
	sep #$20
	.LONGA OFF
	rts

	.LONGA ON
?hw2	lda ?r_pr
	sta.l antdiv_dd
	lda m_den
	sta.l antdiv_ds
	lda.l antdiv_re
	sta m_rem

	lda ?q_hi
	and #$00ff
	xba
	ora.l antdiv_qu
	sta m_quot
	sep #$20
	.LONGA OFF
	rts

	.LONGA ON
?fast16	lda m_prod
	sta.l antdiv_dd
	lda m_den
	sta.l antdiv_ds
	lda.l antdiv_qu
	sta m_quot
	lda.l antdiv_re
	sta m_rem
	sep #$20
	.LONGA OFF
	rts

?q_hi	.word 0
?q_lo	.word 0
?r_pr	.word 0,0
?ds32	.word 0,0
