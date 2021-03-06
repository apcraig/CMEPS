module med_phases_prep_atm_mod

  !-----------------------------------------------------------------------------
  ! Mediator phases for preparing atm export from mediator
  !-----------------------------------------------------------------------------

  use med_kind_mod          , only : CX=>SHR_KIND_CX, CS=>SHR_KIND_CS, CL=>SHR_KIND_CL, R8=>SHR_KIND_R8
  use ESMF                  , only : ESMF_LogWrite, ESMF_LOGMSG_INFO, ESMF_SUCCESS
  use ESMF                  , only : ESMF_FieldBundleGet, ESMF_GridCompGet, ESMF_ClockGet, ESMF_TimeGet
  use ESMF                  , only : ESMF_GridComp, ESMF_Clock, ESMF_Time, ESMF_ClockPrint
  use med_constants_mod     , only : dbug_flag       => med_constants_dbug_flag
  use med_utils_mod         , only : memcheck        => med_memcheck
  use med_utils_mod         , only : chkerr          => med_utils_ChkErr
  use med_methods_mod       , only : FB_fldchk       => med_methods_FB_FldChk
  use med_methods_mod       , only : FB_GetFldPtr    => med_methods_FB_GetFldPtr
  use med_methods_mod       , only : FB_diagnose     => med_methods_FB_diagnose
  use med_methods_mod       , only : FB_init         => med_methods_FB_init
  use med_methods_mod       , only : FB_rest         => med_methods_FB_reset
  use med_methods_mod       , only : FB_getNumFlds   => med_methods_FB_getNumFlds
  use med_methods_mod       , only : State_GetScalar => med_methods_State_GetScalar
  use med_methods_mod       , only : State_SetScalar => med_methods_State_SetScalar
  use med_merge_mod         , only : med_merge_auto
  use med_map_mod           , only : med_map_FB_Regrid_Norm
  use med_internalstate_mod , only : InternalState, mastertask
  use med_phases_ocnalb_mod , only : med_phases_ocnalb_mapo2a
  use esmFlds               , only : compatm, compocn, compice, ncomps, compname
  use esmFlds               , only : fldListFr, fldListTo
  use esmFlds               , only : fldListMed_aoflux
  use esmFlds               , only : coupling_mode
  use perf_mod              , only : t_startf, t_stopf

  implicit none
  private

  public  :: med_phases_prep_atm

  character(*), parameter :: u_FILE_u  = &
       __FILE__

!-----------------------------------------------------------------------------
contains
!-----------------------------------------------------------------------------

  subroutine med_phases_prep_atm(gcomp, rc)

    ! input/output variables
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables
    type(ESMF_Clock)           :: clock
    type(ESMF_Time)            :: time
    character(len=64)          :: timestr
    type(InternalState)        :: is_local
    real(R8), pointer          :: dataPtr1(:),dataPtr2(:)
    integer                    :: i, j, n, n1, ncnt
    integer                    :: dbrc
    character(len=*),parameter :: subname='(med_phases_prep_atm)'
    !-------------------------------------------------------------------------------

    call t_startf('MED:'//subname)
    rc = ESMF_SUCCESS

    if (dbug_flag > 5) then
       call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=dbrc)
    end if
    call memcheck(subname, 3, mastertask)

    !---------------------------------------
    ! --- Get the internal state
    !---------------------------------------

    nullify(is_local%wrap)
    call ESMF_GridCompGetInternalState(gcomp, is_local, rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    !---------------------------------------
    !--- Count the number of fields outside of scalar data, if zero, then return
    !---------------------------------------

    ! Note - the scalar field has been removed from all mediator field bundles - so this is why we check if the
    ! fieldCount is 0 and not 1 here

    call ESMF_FieldBundleGet(is_local%wrap%FBExp(compatm), fieldCount=ncnt, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    if (ncnt == 0) then
       call ESMF_LogWrite(trim(subname)//": only scalar data is present in FBexp(compatm), returning", &
            ESMF_LOGMSG_INFO, rc=dbrc)
    else

       !---------------------------------------
       !--- Get the current time from the clock
       !---------------------------------------
       call ESMF_GridCompGet(gcomp, clock=clock)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       call ESMF_ClockGet(clock,currtime=time,rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       call ESMF_TimeGet(time,timestring=timestr)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       call ESMF_LogWrite(trim(subname)//": time = "//trim(timestr), ESMF_LOGMSG_INFO, rc=dbrc)
       if (dbug_flag > 1) then
          if (mastertask) then
             call ESMF_ClockPrint(clock, options="currTime", &
                  preString="-------->"//trim(subname)//" mediating for: ", rc=rc)
             if (ChkErr(rc,__LINE__,u_FILE_u)) return
          end if
       end if

       !---------------------------------------
       !--- map import field bundles from n1 grid to atm grid - FBimp(:,compatm)
       !---------------------------------------
       do n1 = 1,ncomps
          if (is_local%wrap%med_coupling_active(n1,compatm)) then
             call med_map_FB_Regrid_Norm( &
                  fldsSrc=fldListFr(n1)%flds, &
                  srccomp=n1, destcomp=compatm, &
                  FBSrc=is_local%wrap%FBImp(n1,n1), &
                  FBDst=is_local%wrap%FBImp(n1,compatm), &
                  FBFracSrc=is_local%wrap%FBFrac(n1), &
                  FBNormOne=is_local%wrap%FBNormOne(n1,compatm,:), &
                  RouteHandles=is_local%wrap%RH(n1,compatm,:), &
                  string=trim(compname(n1))//'2'//trim(compname(compatm)), rc=rc)
             if (ChkErr(rc,__LINE__,u_FILE_u)) return
          endif
       enddo

       !---------------------------------------
       !--- map ocean albedos from ocn to atm grid if appropriate
       !---------------------------------------
       if (trim(coupling_mode) == 'cesm') then
          call med_phases_ocnalb_mapo2a(gcomp, rc)
       end if

       !---------------------------------------
       !--- map atm/ocn fluxes from ocn to atm grid if appropriate
       !---------------------------------------
       ! Assumption here is that fluxes are computed on the ocean grid

       if (trim(coupling_mode) == 'cesm' .or. trim(coupling_mode) == 'nems_orig') then
          call med_map_FB_Regrid_Norm(&
               fldsSrc=fldListMed_aoflux%flds, &
               srccomp=compocn, destcomp=compatm, &
               FBSrc=is_local%wrap%FBMed_aoflux_o, &
               FBDst=is_local%wrap%FBMed_aoflux_a, &
               FBFracSrc=is_local%wrap%FBFrac(compocn), &
               FBNormOne=is_local%wrap%FBNormOne(compocn,compatm,:), &
               RouteHandles=is_local%wrap%RH(compocn,compatm,:), &
               string='FBMed_aoflux_o_To_FBMEd_aoflux_a', rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
       endif

       !---------------------------------------
       !--- merge all fields to atm
       !---------------------------------------
       if (trim(coupling_mode) == 'cesm') then
          call med_merge_auto(trim(compname(compatm)), &
               is_local%wrap%FBExp(compatm), is_local%wrap%FBFrac(compatm), &
               is_local%wrap%FBImp(:,compatm), fldListTo(compatm), &
               FBMed1=is_local%wrap%FBMed_ocnalb_a, &
               FBMed2=is_local%wrap%FBMed_aoflux_a, rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
       else if (trim(coupling_mode) == 'nems_orig') then
          call med_merge_auto(trim(compname(compatm)), &
               is_local%wrap%FBExp(compatm), is_local%wrap%FBFrac(compatm), &
               is_local%wrap%FBImp(:,compatm), fldListTo(compatm), &
               FBMed1=is_local%wrap%FBMed_aoflux_a, rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
       else if (trim(coupling_mode) == 'nems_frac') then
          call med_merge_auto(trim(compname(compatm)), &
               is_local%wrap%FBExp(compatm), is_local%wrap%FBFrac(compatm), &
               is_local%wrap%FBImp(:,compatm), fldListTo(compatm), rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
       end if

       if (dbug_flag > 1) then
          call FB_diagnose(is_local%wrap%FBExp(compatm), &
               string=trim(subname)//' FBexp(compatm) ', rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
       end if

       !---------------------------------------
       !--- custom calculations
       !---------------------------------------

       ! set fractions to send back to atm
       if (FB_FldChk(is_local%wrap%FBExp(compatm), 'So_ofrac', rc=rc)) then
          call FB_GetFldPtr(is_local%wrap%FBExp(compatm), 'So_ofrac', dataptr1, rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
          call FB_GetFldPtr(is_local%wrap%FBFrac(compatm), 'ofrac', dataptr2, rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
          do n = 1,size(dataptr1)
             dataptr1(n) = dataptr2(n)
          end do
       end if
       if (FB_FldChk(is_local%wrap%FBExp(compatm), 'Si_ifrac', rc=rc)) then
          call FB_GetFldPtr(is_local%wrap%FBExp(compatm), 'Si_ifrac', dataptr1, rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
          call FB_GetFldPtr(is_local%wrap%FBFrac(compatm), 'ifrac', dataptr2, rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
          do n = 1,size(dataptr1)
             dataptr1(n) = dataptr2(n)
          end do
       end if
       if (FB_FldChk(is_local%wrap%FBExp(compatm), 'Sl_lfrac', rc=rc)) then
          call FB_GetFldPtr(is_local%wrap%FBExp(compatm), 'Sl_lfrac', dataptr1, rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
          call FB_GetFldPtr(is_local%wrap%FBFrac(compatm), 'lfrac', dataptr2, rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
          do n = 1,size(dataptr1)
             dataptr1(n) = dataptr2(n)
          end do
       end if

       !---------------------------------------
       !--- update local scalar data
       !---------------------------------------

       !is_local%wrap%scalar_data(1) =

       !---------------------------------------
       !--- clean up
       !---------------------------------------

    endif

    if (dbug_flag > 5) then
       call ESMF_LogWrite(trim(subname)//": done", ESMF_LOGMSG_INFO, rc=dbrc)
    end if
    call t_stopf('MED:'//subname)

  end subroutine med_phases_prep_atm

end module med_phases_prep_atm_mod
